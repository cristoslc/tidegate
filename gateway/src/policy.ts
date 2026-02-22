/**
 * policy.ts — YAML loader, field validation, tool filtering, response stripping
 *
 * Pure functions, no I/O except YAML loading. Most testable module.
 * Loads tidegate.yaml, validates fields against their classifications,
 * and determines which tools/fields are visible to the agent.
 */

import { readFileSync, watchFile } from "node:fs";
import { parse as parseYaml } from "yaml";

// ── Schema types ──────────────────────────────────────────────

export type FieldClass = "system_param" | "user_content" | "opaque_credential" | "structured_data";
export type ScanLayer = "L1" | "L2" | "L3";
export type TransportType = "http" | "stdio";

export interface FieldMapping {
  class: FieldClass;
  type?: string;
  validation?: string;
  required?: boolean;
  scan?: ScanLayer[];
}

export interface ToolMapping {
  params: Record<string, FieldMapping>;
  response?: Record<string, FieldMapping>;
}

export interface ServerMapping {
  transport: TransportType;
  url?: string;
  command?: string;
  args?: string[];
  env?: Record<string, string>;
  tools: Record<string, ToolMapping>;
}

export interface TidegateConfig {
  version: string;
  defaults: {
    scan_timeout_ms: number;
    scan_failure_mode: "deny" | "allow";
    unknown_field_policy: "deny" | "allow";
  };
  servers: Record<string, ServerMapping>;
}

// ── Validation result types ───────────────────────────────────

export interface ValidationResult {
  allowed: boolean;
  reason?: string;
  field?: string;
  layer?: string;
}

// ── Config loading ────────────────────────────────────────────

let currentConfig: TidegateConfig | null = null;

export function loadConfig(path: string): TidegateConfig {
  const raw = readFileSync(path, "utf-8");
  const parsed = parseYaml(raw) as TidegateConfig;
  currentConfig = parsed;
  return parsed;
}

export function watchConfig(path: string, onReload: (config: TidegateConfig) => void): void {
  watchFile(path, { interval: 1000 }, () => {
    try {
      const config = loadConfig(path);
      onReload(config);
    } catch (err) {
      console.error(`[policy] Failed to reload config: ${err}`);
    }
  });
}

export function getConfig(): TidegateConfig {
  if (!currentConfig) {
    throw new Error("[policy] Config not loaded. Call loadConfig() first.");
  }
  return currentConfig;
}

// ── Tool resolution ───────────────────────────────────────────

/**
 * Resolve which server a tool belongs to, from the mapping.
 * Returns null if the tool is unmapped (invisible to agent).
 */
export function resolveToolServer(
  config: TidegateConfig,
  toolName: string
): { serverName: string; server: ServerMapping; tool: ToolMapping } | null {
  for (const [serverName, server] of Object.entries(config.servers)) {
    const tool = server.tools[toolName];
    if (tool) {
      return { serverName, server, tool };
    }
  }
  return null;
}

/**
 * Get all mapped tool names across all servers.
 */
export function getMappedToolNames(config: TidegateConfig): string[] {
  const names: string[] = [];
  for (const server of Object.values(config.servers)) {
    names.push(...Object.keys(server.tools));
  }
  return names;
}

// ── Field validation ──────────────────────────────────────────

/**
 * Validate a single field value against its mapping.
 * Does NOT perform leak scanning — that's scanner.ts's job.
 */
export function validateField(
  fieldName: string,
  value: unknown,
  mapping: FieldMapping
): ValidationResult {
  // opaque_credential must never appear in agent requests
  if (mapping.class === "opaque_credential") {
    return {
      allowed: false,
      reason: `Field '${fieldName}' is classified as opaque_credential and must not appear in agent requests`,
      field: fieldName,
      layer: "policy",
    };
  }

  // Type validation for system_param
  if (mapping.class === "system_param") {
    // Type check
    if (mapping.type === "string" && typeof value !== "string") {
      return {
        allowed: false,
        reason: `Field '${fieldName}' expected string, got ${typeof value}`,
        field: fieldName,
        layer: "policy",
      };
    }
    if (mapping.type === "number" && typeof value !== "number") {
      return {
        allowed: false,
        reason: `Field '${fieldName}' expected number, got ${typeof value}`,
        field: fieldName,
        layer: "policy",
      };
    }
    if (mapping.type === "boolean" && typeof value !== "boolean") {
      return {
        allowed: false,
        reason: `Field '${fieldName}' expected boolean, got ${typeof value}`,
        field: fieldName,
        layer: "policy",
      };
    }

    // Regex validation
    if (mapping.validation && typeof value === "string") {
      const match = mapping.validation.match(/^regex:(.+)$/);
      if (match?.[1]) {
        const regex = new RegExp(match[1]);
        if (!regex.test(value)) {
          return {
            allowed: false,
            reason: `Field '${fieldName}' failed regex validation: ${match[1]}`,
            field: fieldName,
            layer: "policy",
          };
        }
      }

      // Enum validation
      const enumMatch = mapping.validation.match(/^enum:(.+)$/);
      if (enumMatch?.[1]) {
        const allowed = enumMatch[1].split(",").map((s) => s.trim());
        if (!allowed.includes(value)) {
          return {
            allowed: false,
            reason: `Field '${fieldName}' not in allowed values: ${allowed.join(", ")}`,
            field: fieldName,
            layer: "policy",
          };
        }
      }
    }
  }

  return { allowed: true };
}

/**
 * Validate all fields in a tool call against the tool's mapping.
 * Checks: all fields mapped, no extra fields, required fields present,
 * each field validates against its class.
 */
export function validateToolCall(
  toolName: string,
  args: Record<string, unknown>,
  toolMapping: ToolMapping,
  unknownFieldPolicy: "deny" | "allow"
): ValidationResult {
  const paramMappings = toolMapping.params;

  // Check for required fields
  for (const [fieldName, mapping] of Object.entries(paramMappings)) {
    if (mapping.required && !(fieldName in args)) {
      return {
        allowed: false,
        reason: `Required field '${fieldName}' missing from tool '${toolName}'`,
        field: fieldName,
        layer: "policy",
      };
    }
  }

  // Check each provided field
  for (const [fieldName, value] of Object.entries(args)) {
    const mapping = paramMappings[fieldName];

    // Unknown field
    if (!mapping) {
      if (unknownFieldPolicy === "deny") {
        return {
          allowed: false,
          reason: `Unknown field '${fieldName}' in tool '${toolName}' — not in schema mapping`,
          field: fieldName,
          layer: "policy",
        };
      }
      continue;
    }

    // Validate field
    const result = validateField(fieldName, value, mapping);
    if (!result.allowed) {
      return result;
    }
  }

  return { allowed: true };
}

/**
 * Get fields that need leak scanning (user_content and structured_data with scan config).
 */
export function getFieldsToScan(
  args: Record<string, unknown>,
  toolMapping: ToolMapping
): Array<{ fieldName: string; value: unknown; mapping: FieldMapping }> {
  const result: Array<{ fieldName: string; value: unknown; mapping: FieldMapping }> = [];

  for (const [fieldName, value] of Object.entries(args)) {
    const mapping = toolMapping.params[fieldName];
    if (!mapping) continue;

    if (mapping.class === "user_content" || mapping.class === "structured_data") {
      if (mapping.scan && mapping.scan.length > 0) {
        result.push({ fieldName, value, mapping });
      }
    }
  }

  return result;
}

/**
 * Strip unmapped fields from a response object.
 */
export function stripUnmappedResponseFields(
  response: Record<string, unknown>,
  responseMapping: Record<string, FieldMapping> | undefined
): Record<string, unknown> {
  if (!responseMapping) return {};

  const stripped: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(response)) {
    if (key in responseMapping) {
      stripped[key] = value;
    }
  }
  return stripped;
}
