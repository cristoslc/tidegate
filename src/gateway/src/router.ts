/**
 * router.ts — Request lifecycle orchestration
 *
 * Pipeline: tool found? → allowed? → scan all string values →
 * forward via servers.ts → scan response → return
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

// ── Recursive string extraction ───────────────────────────────

/**
 * Recursively extract all string values from an object or array.
 * Returns an array of { path, value } pairs for audit trail clarity.
 *
 * Examples:
 *   { message: "hello" }           → [{ path: "message", value: "hello" }]
 *   { config: { name: "foo" } }    → [{ path: "config.name", value: "foo" }]
 *   { items: ["a", "b"] }          → [{ path: "items[0]", value: "a" }, ...]
 */
function extractStringValues(
  obj: Record<string, unknown>,
  prefix: string = ""
): Array<{ path: string; value: string }> {
  const results: Array<{ path: string; value: string }> = [];

  for (const [key, val] of Object.entries(obj)) {
    const currentPath = prefix ? `${prefix}.${key}` : key;
    collectStrings(val, currentPath, results);
  }

  return results;
}

function collectStrings(
  val: unknown,
  path: string,
  results: Array<{ path: string; value: string }>
): void {
  if (typeof val === "string") {
    results.push({ path, value: val });
  } else if (Array.isArray(val)) {
    for (let i = 0; i < val.length; i++) {
      collectStrings(val[i], `${path}[${i}]`, results);
    }
  } else if (val !== null && typeof val === "object") {
    for (const [key, nested] of Object.entries(val as Record<string, unknown>)) {
      collectStrings(nested, `${path}.${key}`, results);
    }
  }
  // Non-string primitives (number, boolean, null, undefined) are not scanned
}

// ── Tool list filtering ───────────────────────────────────────

/**
 * Get the filtered tool list — all discovered tools, filtered by allow_tools.
 * Merges tools from all downstream servers.
 */
export function getFilteredTools(): Tool[] {
  const config = policy.getConfig();
  const allDownstreamTools = servers.getAllTools();
  const filtered: Tool[] = [];

  for (const [serverName, tools] of allDownstreamTools) {
    const serverConfig = config.servers[serverName];
    for (const tool of tools) {
      if (serverConfig && !policy.isToolAllowed(serverConfig, tool.name)) {
        continue;
      }
      filtered.push(tool);
    }
  }

  return filtered;
}

// ── Tool call handling ────────────────────────────────────────

/**
 * Handle a tool call from the agent.
 * Full enforcement pipeline: resolve → allowed? → scan → forward → scan response → return.
 */
export async function handleToolCall(
  toolName: string,
  args: Record<string, unknown>
): Promise<CallToolResult> {
  const elapsed = startTimer();
  const config = policy.getConfig();

  // Step 1: Resolve tool → server (from discovered tools)
  const serverName = servers.resolveToolServer(toolName);
  if (!serverName) {
    const reason = `Tool '${toolName}' not found on any downstream server`;
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

  // Step 2: Tool allowed? (check allow_tools if configured)
  const serverConfig = config.servers[serverName];
  if (serverConfig && !policy.isToolAllowed(serverConfig, toolName)) {
    const reason = `Tool '${toolName}' is not in the allow_tools list for server '${serverName}'`;
    writeAuditEntry({
      timestamp: new Date().toISOString(),
      tool: toolName,
      server: serverName,
      verdict: "deny",
      layer: "policy",
      reason,
      durationMs: elapsed(),
    });
    return shapedDeny(toolName, reason);
  }

  // Step 3: Scan ALL string values in args
  const stringValues = extractStringValues(args);
  for (const { path, value } of stringValues) {
    const scanResult = await scanner.scanValue(value, config.defaults.scan_timeout_ms);
    if (!scanResult.allowed) {
      const reason = `tool '${toolName}' parameter '${path}' contains ${scanResult.reason}`;
      writeAuditEntry({
        timestamp: new Date().toISOString(),
        tool: toolName,
        server: serverName,
        verdict: "deny",
        layer: scanResult.layer as AuditLayer,
        param_path: path,
        reason,
        durationMs: elapsed(),
      });
      return shapedDeny(toolName, reason);
    }
  }

  // Step 4: Forward to downstream MCP server
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

  // Step 5: Scan response text content
  if (downstreamResult.content && Array.isArray(downstreamResult.content)) {
    for (const item of downstreamResult.content) {
      if (item.type === "text" && typeof item.text === "string") {
        const scanResult = await scanner.scanValue(item.text, config.defaults.scan_timeout_ms);
        if (!scanResult.allowed) {
          const reason = `Response from tool '${toolName}' contains ${scanResult.reason}`;
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
