/**
 * policy.ts — Config loading and tool allowlists
 *
 * Loads tidegate.yaml. Determines which tools are allowed per server.
 * Pure functions, no I/O except YAML loading.
 *
 * Mirror+scan model: the gateway discovers tools from downstream servers
 * and scans ALL string values. No per-field YAML mappings needed.
 */

import { readFileSync } from "node:fs";
import { parse as parseYaml } from "yaml";

// ── Schema types ──────────────────────────────────────────────

export type TransportType = "http" | "stdio";

export interface ServerConfig {
  transport: TransportType;
  url?: string;
  command?: string;
  args?: string[];
  env?: Record<string, string>;
  allow_tools?: string[];  // optional allowlist; omit to mirror all
}

export interface TidegateConfig {
  version: string;
  defaults: {
    scan_timeout_ms: number;
    scan_failure_mode: "deny" | "allow";
  };
  servers: Record<string, ServerConfig>;
}

// ── Config loading ────────────────────────────────────────────

let currentConfig: TidegateConfig | null = null;

export function loadConfig(path: string): TidegateConfig {
  const raw = readFileSync(path, "utf-8");
  const parsed = parseYaml(raw) as TidegateConfig;
  currentConfig = parsed;
  return parsed;
}

export function getConfig(): TidegateConfig {
  if (!currentConfig) {
    throw new Error("[policy] Config not loaded. Call loadConfig() first.");
  }
  return currentConfig;
}

// ── Tool allowlist ────────────────────────────────────────────

/**
 * Check if a tool is allowed by a server's allow_tools list.
 * If allow_tools is not configured, all tools are allowed.
 */
export function isToolAllowed(serverConfig: ServerConfig, toolName: string): boolean {
  if (!serverConfig.allow_tools) return true;
  return serverConfig.allow_tools.includes(toolName);
}
