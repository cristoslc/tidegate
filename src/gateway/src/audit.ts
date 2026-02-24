/**
 * audit.ts — Structured NDJSON logging
 *
 * Every allow/deny/error is logged with tool, field, reason, layer, and duration.
 * Writes are synchronous and append-only — the log entry is written before the
 * response is forwarded. This module has no knowledge of policy or scanning logic.
 */

export type AuditVerdict = "allow" | "deny" | "error";

export type AuditLayer = "policy" | "scanner_l1" | "scanner_l2" | "scanner_l3" | "downstream" | "gateway";

export interface AuditEntry {
  timestamp: string;
  tool: string;
  server: string;
  verdict: AuditVerdict;
  layer: AuditLayer;
  field?: string;
  reason?: string;
  durationMs: number;
}

/**
 * Write a structured audit log entry to stdout as NDJSON.
 * Synchronous — must complete before response is forwarded.
 */
export function writeAuditEntry(entry: AuditEntry): void {
  const line = JSON.stringify(entry);
  process.stdout.write(line + "\n");
}

/**
 * Create a timer for measuring request duration.
 */
export function startTimer(): () => number {
  const start = performance.now();
  return () => Math.round(performance.now() - start);
}
