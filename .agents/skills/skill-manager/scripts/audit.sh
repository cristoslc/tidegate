#!/usr/bin/env bash
# audit.sh — Safety audit for installed agent skills
#
# Scans a skill directory for patterns that indicate security risks:
# exfiltration, env harvesting, credential access, obfuscation,
# reverse shells, curl-pipe-shell, prompt injection, known malicious.
#
# Usage:
#   audit.sh <skill-dir>
#
# Exit codes:
#   0 — clean (no findings)
#   1 — warnings only
#   2 — critical findings (caller should rollback)

set -euo pipefail

SKILL_DIR="${1:?Usage: audit.sh <skill-dir>}"

if [ ! -d "$SKILL_DIR" ]; then
  echo "ERROR: Directory not found: $SKILL_DIR" >&2
  exit 2
fi

FINDINGS="$(mktemp)"
cleanup() { rm -f "$FINDINGS"; }
trap cleanup EXIT

CRITICAL=0
WARNING=0

# --- Pattern scanner ---
# scan_pattern <severity> <pattern> <description> [file-glob]
scan_pattern() {
  local severity="$1" pattern="$2" description="$3" file_glob="${4:-}"
  local grep_opts="-rnE"
  local matches

  if [ -n "$file_glob" ]; then
    matches="$(grep $grep_opts --include="$file_glob" "$pattern" "$SKILL_DIR" 2>/dev/null || true)"
  else
    matches="$(grep $grep_opts "$pattern" "$SKILL_DIR" 2>/dev/null || true)"
  fi

  if [ -n "$matches" ]; then
    echo "[$severity] $description" >> "$FINDINGS"
    echo "$matches" | while IFS= read -r line; do
      echo "  $line" >> "$FINDINGS"
    done
    echo "" >> "$FINDINGS"

    if [ "$severity" = "CRITICAL" ]; then
      CRITICAL=$((CRITICAL + 1))
    else
      WARNING=$((WARNING + 1))
    fi
  fi
}

echo "=== Skill Safety Audit ==="
echo "Target: $SKILL_DIR"
echo ""

# --- Exfiltration ---
scan_pattern "CRITICAL" 'curl\s+.*-X\s*POST' "Outbound POST request via curl" "*.sh"
scan_pattern "CRITICAL" 'curl\s+.*--data' "Outbound data exfiltration via curl" "*.sh"
scan_pattern "CRITICAL" 'wget\s+.*--post' "Outbound POST via wget" "*.sh"
scan_pattern "WARNING" 'curl\s+.*-o\s' "File download via curl" "*.sh"

# --- Environment harvesting ---
scan_pattern "CRITICAL" 'printenv|/proc/self/environ' "Full environment dump" "*.sh"
scan_pattern "WARNING" '\$\{?[A-Z_]*KEY[A-Z_]*\}?' "References to KEY-named env vars" "*.sh"
scan_pattern "WARNING" '\$\{?[A-Z_]*TOKEN[A-Z_]*\}?' "References to TOKEN-named env vars" "*.sh"
scan_pattern "WARNING" '\$\{?[A-Z_]*SECRET[A-Z_]*\}?' "References to SECRET-named env vars" "*.sh"

# --- Credential access ---
scan_pattern "CRITICAL" '~/.ssh/|\.ssh/id_' "SSH key access" "*.sh"
scan_pattern "CRITICAL" '~/.aws/|AWS_SECRET|aws configure' "AWS credential access" "*.sh"
scan_pattern "CRITICAL" '~/.netrc|\.netrc' "netrc credential file access" "*.sh"
scan_pattern "CRITICAL" '\.env\b' "Dotenv file access" "*.sh"
scan_pattern "CRITICAL" 'credentials\.json|service.account\.json' "Service account credential access"

# --- Obfuscation ---
scan_pattern "CRITICAL" 'base64\s+(-d|--decode)' "Base64 decode (potential obfuscation)" "*.sh"
scan_pattern "CRITICAL" '\beval\b.*\$' "Dynamic eval with variable expansion" "*.sh"
scan_pattern "WARNING" '\beval\b' "Use of eval" "*.sh"

# --- Reverse shells ---
scan_pattern "CRITICAL" '/dev/tcp/|/dev/udp/' "Network device access (reverse shell)" "*.sh"
scan_pattern "CRITICAL" 'nc\s+-[el]|ncat\s+-[el]|socat\s+' "Netcat/socat listener" "*.sh"
scan_pattern "CRITICAL" 'bash\s+-i.*>&.*/dev/tcp' "Bash reverse shell" "*.sh"

# --- Curl-pipe-shell ---
scan_pattern "CRITICAL" 'curl\s.*\|\s*(ba)?sh' "Curl piped to shell" "*.sh"
scan_pattern "CRITICAL" 'wget\s.*\|\s*(ba)?sh' "Wget piped to shell" "*.sh"
scan_pattern "CRITICAL" 'curl\s.*\|\s*python' "Curl piped to python" "*.sh"

# --- Prompt injection ---
scan_pattern "WARNING" 'ignore\s+(previous|all|above)\s+instructions' "Potential prompt injection" "*.md"
scan_pattern "WARNING" 'you\s+are\s+now\s+' "Potential role hijacking" "*.md"
scan_pattern "WARNING" 'system\s*:\s*you\s+are' "Potential system prompt override" "*.md"

# --- Known malicious patterns ---
scan_pattern "CRITICAL" 'rm\s+-rf\s+/' "Recursive delete from root" "*.sh"
scan_pattern "CRITICAL" 'chmod\s+777' "World-writable permissions" "*.sh"
scan_pattern "CRITICAL" 'mkfifo.*nc\s' "Named pipe with netcat" "*.sh"

# --- Report ---
echo "--- Findings ---"

if [ -s "$FINDINGS" ]; then
  cat "$FINDINGS"
  echo "=== Audit complete: $CRITICAL critical, $WARNING warnings ==="
else
  echo "(none)"
  echo ""
  echo "=== Audit complete: clean ==="
fi

if [ "$CRITICAL" -gt 0 ]; then
  exit 2
elif [ "$WARNING" -gt 0 ]; then
  exit 1
else
  exit 0
fi
