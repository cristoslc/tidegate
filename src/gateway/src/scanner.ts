/**
 * scanner.ts — Leak detection interface
 *
 * L1 scanning runs in-process (TypeScript). L2/L3 go to Python subprocess.
 *
 * Scanner is stateless — no tool context, no session state. It receives
 * only a value and returns allow/deny. The gateway decides which values
 * to scan; the scanner has no knowledge of field names or classes.
 *
 * The Python subprocess communicates via NDJSON over stdin/stdout:
 *   Request:  {"value": "..."}
 *   Response: {"allowed": true} or {"allowed": false, "reason": "...", "layer": "scanner_l2"}
 *
 * Subprocess lifecycle:
 *   - Spawned once at gateway startup via initScanner()
 *   - Stays alive for the lifetime of the gateway process
 *   - Auto-respawns on crash (with backoff)
 *   - Fail-closed: if subprocess is unavailable, scan fails (deny)
 */

import { spawn, type ChildProcess } from "node:child_process";
import { createInterface, type Interface as ReadlineInterface } from "node:readline";

export interface ScanResult {
  allowed: boolean;
  reason?: string;
  layer: "scanner_l1" | "scanner_l2" | "scanner_l3";
}

// ── Python subprocess management ─────────────────────────────

const SCANNER_SCRIPT = process.env["TIDEGATE_SCANNER_PATH"] ?? "/app/scanner/scanner.py";
const PYTHON_BIN = process.env["TIDEGATE_PYTHON_BIN"] ?? "python3";
const RESPAWN_DELAY_MS = 1000;
const MAX_RESPAWN_ATTEMPTS = 5;

let scannerProcess: ChildProcess | null = null;
let scannerReadline: ReadlineInterface | null = null;
let responseQueue: Array<(response: SubprocessResponse) => void> = [];
let respawnAttempts = 0;
let scannerReady = false;

interface SubprocessRequest {
  value: string;
}

interface SubprocessResponse {
  allowed: boolean;
  reason?: string;
  layer?: string;
}

/**
 * Spawn (or respawn) the Python scanner subprocess.
 */
function spawnScanner(): void {
  if (scannerProcess) {
    scannerProcess.removeAllListeners();
    scannerProcess.kill();
    scannerProcess = null;
  }

  scannerReadline = null;
  scannerReady = false;

  try {
    scannerProcess = spawn(PYTHON_BIN, ["-u", SCANNER_SCRIPT], {
      stdio: ["pipe", "pipe", "pipe"],
    });
  } catch (err) {
    console.error(`[scanner] Failed to spawn Python subprocess: ${err}`);
    return;
  }

  if (!scannerProcess.stdout || !scannerProcess.stdin) {
    console.error("[scanner] Subprocess has no stdout/stdin — cannot communicate");
    return;
  }

  // Read NDJSON responses from stdout
  scannerReadline = createInterface({ input: scannerProcess.stdout });

  scannerReadline.on("line", (line: string) => {
    const resolver = responseQueue.shift();
    if (!resolver) {
      console.error(`[scanner] Received unexpected response from subprocess: ${line}`);
      return;
    }

    try {
      const response = JSON.parse(line) as SubprocessResponse;
      resolver(response);
    } catch {
      console.error(`[scanner] Failed to parse subprocess response: ${line}`);
      resolver({ allowed: false, reason: "Scanner returned invalid JSON", layer: "scanner_l2" });
    }
  });

  // Forward stderr for logging
  if (scannerProcess.stderr) {
    const stderrRl = createInterface({ input: scannerProcess.stderr });
    stderrRl.on("line", (line: string) => {
      console.error(`[scanner:py] ${line}`);
    });
  }

  // Handle subprocess exit
  scannerProcess.on("exit", (code, signal) => {
    console.error(`[scanner] Python subprocess exited (code=${code}, signal=${signal})`);
    scannerReady = false;

    // Reject all pending requests
    const pending = responseQueue.splice(0);
    for (const resolver of pending) {
      resolver({ allowed: false, reason: "Scanner subprocess exited unexpectedly", layer: "scanner_l2" });
    }

    // Auto-respawn with backoff
    if (respawnAttempts < MAX_RESPAWN_ATTEMPTS) {
      respawnAttempts++;
      const delay = RESPAWN_DELAY_MS * respawnAttempts;
      console.error(`[scanner] Respawning in ${delay}ms (attempt ${respawnAttempts}/${MAX_RESPAWN_ATTEMPTS})`);
      setTimeout(() => spawnScanner(), delay);
    } else {
      console.error("[scanner] Max respawn attempts reached — scanner is offline. All L2/L3 scans will fail-closed (deny).");
    }
  });

  scannerProcess.on("error", (err) => {
    console.error(`[scanner] Subprocess error: ${err.message}`);
  });

  scannerReady = true;
  respawnAttempts = 0; // Reset on successful spawn
  console.error("[scanner] Python L2/L3 subprocess spawned");
}

/**
 * Initialize the scanner subprocess. Call once at gateway startup.
 */
export function initScanner(): void {
  spawnScanner();
}

/**
 * Stop the scanner subprocess. Call during graceful shutdown.
 */
export function stopScanner(): void {
  if (scannerProcess) {
    scannerProcess.removeAllListeners();
    scannerProcess.kill("SIGTERM");
    scannerProcess = null;
    scannerReadline = null;
    scannerReady = false;
    responseQueue = [];
  }
}

/**
 * Send a scan request to the Python subprocess and wait for a response.
 * Returns a deny ScanResult if the subprocess is unavailable or times out.
 */
async function scanSubprocess(
  value: string,
  timeoutMs: number
): Promise<ScanResult> {
  if (!scannerReady || !scannerProcess?.stdin) {
    return {
      allowed: false,
      reason: "Scanner subprocess is not available — fail-closed",
      layer: "scanner_l2",
    };
  }

  const request: SubprocessRequest = {
    value,
  };

  return new Promise<ScanResult>((resolve) => {
    // Timeout race
    const timer = setTimeout(() => {
      // Remove this resolver from the queue (it timed out)
      const idx = responseQueue.indexOf(resolver);
      if (idx !== -1) {
        responseQueue.splice(idx, 1);
      }
      resolve({
        allowed: false,
        reason: `Scanner subprocess timed out after ${timeoutMs}ms — fail-closed`,
        layer: "scanner_l2",
      });
    }, timeoutMs);

    const resolver = (response: SubprocessResponse) => {
      clearTimeout(timer);
      resolve({
        allowed: response.allowed,
        reason: response.reason,
        layer: (response.layer as ScanResult["layer"]) ?? "scanner_l2",
      });
    };

    responseQueue.push(resolver);

    try {
      const line = JSON.stringify(request) + "\n";
      scannerProcess!.stdin!.write(line);
    } catch (err) {
      // Remove resolver if write fails
      const idx = responseQueue.indexOf(resolver);
      if (idx !== -1) {
        responseQueue.splice(idx, 1);
      }
      clearTimeout(timer);
      resolve({
        allowed: false,
        reason: `Failed to write to scanner subprocess: ${err}`,
        layer: "scanner_l2",
      });
    }
  });
}

// ── L1: Key-name and vendor-prefix heuristics (in-process) ────

/**
 * Patterns that indicate credential-like values.
 * These fire on the VALUE, not the field name (we already know the field name
 * from schema mappings — L1 catches credentials embedded in free-text fields).
 */
const CREDENTIAL_PATTERNS: Array<{ name: string; pattern: RegExp }> = [
  // AWS
  { name: "AWS access key", pattern: /\bAKIA[0-9A-Z]{16}\b/ },
  { name: "AWS secret key", pattern: /\b[A-Za-z0-9/+=]{40}\b/ },

  // Slack
  { name: "Slack bot token", pattern: /\bxoxb-[0-9]+-[0-9A-Za-z]+\b/ },
  { name: "Slack user token", pattern: /\bxoxp-[0-9]+-[0-9A-Za-z]+\b/ },
  { name: "Slack webhook", pattern: /\bhttps:\/\/hooks\.slack\.com\/services\/T[A-Z0-9]+\/B[A-Z0-9]+\/[A-Za-z0-9]+\b/ },

  // GitHub
  { name: "GitHub PAT (classic)", pattern: /\bghp_[A-Za-z0-9]{36}\b/ },
  { name: "GitHub PAT (fine-grained)", pattern: /\bgithub_pat_[A-Za-z0-9_]{82}\b/ },
  { name: "GitHub OAuth token", pattern: /\bgho_[A-Za-z0-9]{36}\b/ },

  // Stripe
  { name: "Stripe secret key", pattern: /\bsk_live_[A-Za-z0-9]{24,}\b/ },
  { name: "Stripe publishable key", pattern: /\bpk_live_[A-Za-z0-9]{24,}\b/ },

  // Generic
  { name: "Generic API key", pattern: /\b[A-Za-z0-9]{32,}(?:_key|_secret|_token)\b/i },
  { name: "Bearer token", pattern: /\bBearer\s+[A-Za-z0-9\-._~+/]+=*\b/ },
  { name: "Private key block", pattern: /-----BEGIN (?:RSA |EC |DSA )?PRIVATE KEY-----/ },

  // 1Password
  { name: "1Password SA token", pattern: /\bops_[A-Za-z0-9]{43,}\b/ },
];

/**
 * Patterns that match JSON key names suggesting sensitive data.
 * These scan for sensitive keys inside free-text that might contain JSON.
 */
const SENSITIVE_KEY_PATTERNS: RegExp[] = [
  /["'](?:ssn|social_security|social_security_number)["']\s*:/i,
  /["'](?:password|passwd|pwd|secret)["']\s*:/i,
  /["'](?:api_key|apikey|api_secret|access_key|secret_key)["']\s*:/i,
  /["'](?:credit_card|card_number|ccn|cvv|cvc)["']\s*:/i,
  /["'](?:private_key|priv_key)["']\s*:/i,
  /["'](?:auth_token|access_token|refresh_token|bearer)["']\s*:/i,
  /["'](?:bank_account|routing_number|account_number)["']\s*:/i,
];

/**
 * L1 scan: in-process heuristics for credential patterns and sensitive JSON keys.
 */
export function scanL1(value: unknown): ScanResult {
  if (typeof value !== "string") {
    return { allowed: true, layer: "scanner_l1" };
  }

  // Check for credential patterns in the value
  for (const { name, pattern } of CREDENTIAL_PATTERNS) {
    if (pattern.test(value)) {
      return {
        allowed: false,
        reason: `Value contains a pattern matching ${name} (${pattern.source.slice(0, 30)}...)`,
        layer: "scanner_l1",
      };
    }
  }

  // Check for sensitive JSON keys embedded in the value
  for (const pattern of SENSITIVE_KEY_PATTERNS) {
    if (pattern.test(value)) {
      return {
        allowed: false,
        reason: `Value contains JSON with sensitive key name (${pattern.source.slice(0, 40)}...)`,
        layer: "scanner_l1",
      };
    }
  }

  return { allowed: true, layer: "scanner_l1" };
}

/**
 * Scan a value through all detection layers.
 * L1 runs in-process. L2/L3 go to the Python subprocess.
 *
 * The scanner has no knowledge of field names or classes. The caller
 * (router.ts) decides which values to scan; this function runs ALL
 * checks on whatever value it receives.
 */
export async function scanValue(
  value: unknown,
  timeoutMs: number = 500
): Promise<ScanResult> {
  // L1: always in-process, synchronous
  const l1Result = scanL1(value);
  if (!l1Result.allowed) return l1Result;

  // L2/L3: delegate to Python subprocess
  if (typeof value === "string") {
    const result = await scanSubprocess(value, timeoutMs);
    if (!result.allowed) return result;
  }

  return { allowed: true, layer: "scanner_l1" };
}
