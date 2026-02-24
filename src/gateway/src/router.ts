/**
 * router.ts — Request lifecycle orchestration
 *
 * Pipeline: tool mapped? → fields mapped? → no extra fields? →
 * system_param validates? → user_content scans clean? →
 * forward via servers.ts → response clean? → return
 *
 * Denial at any step short-circuits with a shaped deny.
 * servers.ts is never called on the deny path.
 */

import type { Tool, CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import * as policy from "./policy.js";
import * as scanner from "./scanner.js";
import * as servers from "./servers.js";
import { writeAuditEntry, startTimer, type AuditLayer } from "./audit.js";

// ── Shaped deny construction ──────────────────────────────────

/**
 * Construct a shaped deny as a valid MCP tool result.
 * isError: false is deliberate — the agent reads and adjusts,
 * rather than treating it as a system error and retrying blindly.
 */
function shapedDeny(toolName: string, reason: string): CallToolResult {
  return {
    content: [
      {
        type: "text",
        text: `Policy violation: ${reason}`,
      },
    ],
    isError: false,
  };
}

// ── Tool list filtering ───────────────────────────────────────

/**
 * Get the filtered tool list — only mapped tools are visible to the agent.
 * Merges tools from all downstream servers, filtering against policy.
 */
export function getFilteredTools(): Tool[] {
  const config = policy.getConfig();
  const mappedNames = new Set(policy.getMappedToolNames(config));
  const allDownstreamTools = servers.getAllTools();
  const filtered: Tool[] = [];

  for (const [_serverName, tools] of allDownstreamTools) {
    for (const tool of tools) {
      if (mappedNames.has(tool.name)) {
        filtered.push(tool);
      }
    }
  }

  return filtered;
}

// ── Tool call handling ────────────────────────────────────────

/**
 * Handle a tool call from the agent.
 * Full enforcement pipeline: validate → scan → forward → scan response → return.
 */
export async function handleToolCall(
  toolName: string,
  args: Record<string, unknown>
): Promise<CallToolResult> {
  const elapsed = startTimer();
  const config = policy.getConfig();

  // Step 1: Tool mapped?
  const resolution = policy.resolveToolServer(config, toolName);
  if (!resolution) {
    const reason = `Tool '${toolName}' is not mapped — invisible to agent`;
    writeAuditEntry({
      timestamp: new Date().toISOString(),
      tool: toolName,
      server: "unknown",
      verdict: "deny",
      layer: "policy",
      reason,
      durationMs: elapsed(),
    });
    return shapedDeny(toolName, reason);
  }

  const { serverName, tool: toolMapping } = resolution;

  // Step 2-4: Field validation (mapped? no extras? system_param validates?)
  const validationResult = policy.validateToolCall(
    toolName,
    args,
    toolMapping,
    config.defaults.unknown_field_policy
  );

  if (!validationResult.allowed) {
    writeAuditEntry({
      timestamp: new Date().toISOString(),
      tool: toolName,
      server: serverName,
      verdict: "deny",
      layer: "policy",
      field: validationResult.field,
      reason: validationResult.reason,
      durationMs: elapsed(),
    });
    return shapedDeny(toolName, validationResult.reason ?? "Field validation failed");
  }

  // Step 5: Leak scan on user_content fields
  const fieldsToScan = policy.getFieldsToScan(args, toolMapping);
  for (const { fieldName, value } of fieldsToScan) {
    const scanResult = await scanner.scanValue(value, config.defaults.scan_timeout_ms);
    if (!scanResult.allowed) {
      const reason = `Field '${fieldName}' in tool '${toolName}' failed ${scanResult.layer} scan — ${scanResult.reason}`;
      writeAuditEntry({
        timestamp: new Date().toISOString(),
        tool: toolName,
        server: serverName,
        verdict: "deny",
        layer: scanResult.layer as AuditLayer,
        field: fieldName,
        reason,
        durationMs: elapsed(),
      });
      return shapedDeny(toolName, reason);
    }
  }

  // Step 6: Forward to downstream MCP server
  let downstreamResult: CallToolResult;
  try {
    downstreamResult = await servers.forward(serverName, toolName, args);
  } catch (err) {
    const reason = `Downstream error from '${serverName}': ${err instanceof Error ? err.message : String(err)}`;
    writeAuditEntry({
      timestamp: new Date().toISOString(),
      tool: toolName,
      server: serverName,
      verdict: "error",
      layer: "downstream",
      reason,
      durationMs: elapsed(),
    });
    return shapedDeny(toolName, reason);
  }

  // Step 7-8: Response scanning — scan all text content for leaks before returning to agent
  if (downstreamResult.content && Array.isArray(downstreamResult.content)) {
    for (const item of downstreamResult.content) {
      if (item.type === "text" && typeof item.text === "string") {
        const scanResult = await scanner.scanValue(item.text, config.defaults.scan_timeout_ms);
        if (!scanResult.allowed) {
          const reason = `Response from tool '${toolName}' failed ${scanResult.layer} scan — ${scanResult.reason}`;
          writeAuditEntry({
            timestamp: new Date().toISOString(),
            tool: toolName,
            server: serverName,
            verdict: "deny",
            layer: scanResult.layer as AuditLayer,
            reason,
            durationMs: elapsed(),
          });
          return shapedDeny(toolName, reason);
        }
      }
    }
  }

  // Log allow
  writeAuditEntry({
    timestamp: new Date().toISOString(),
    tool: toolName,
    server: serverName,
    verdict: "allow",
    layer: "gateway",
    durationMs: elapsed(),
  });

  return downstreamResult;
}
