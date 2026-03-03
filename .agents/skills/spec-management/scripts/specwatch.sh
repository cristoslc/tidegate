#!/bin/bash
# specwatch.sh — Background filesystem watcher for stale path references in docs/
# Detects file moves/renames/deletes and flags stale markdown links with suggested fixes.
# Uses fswatch (macOS FSEvents) with a sentinel-based inactivity timeout.

set -euo pipefail

# --- Resolve repo root ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
DOCS_DIR="$REPO_ROOT/docs"
LOG_FILE="$REPO_ROOT/.agents/specwatch.log"

# --- Sentinel and PID paths (repo-specific) ---
REPO_HASH=$(printf '%s' "$REPO_ROOT" | shasum -a 256 | cut -c1-12)
SENTINEL="/tmp/.specwatch-sentinel-${REPO_HASH}"
PID_FILE="/tmp/.specwatch-pid-${REPO_HASH}"

# --- Defaults ---
TIMEOUT_SECS="${SPECWATCH_TIMEOUT:-3600}"   # 1 hour
CHECK_INTERVAL=60                            # seconds between sentinel age checks
DEBOUNCE_SECS=1                              # batch window for fswatch events

# --- Helpers ---

usage() {
  cat <<'USAGE'
Usage: specwatch.sh <command> [args]

Commands:
  watch              Start background filesystem watcher (default)
  scan               Run a full stale-reference scan (no watcher)
  stop               Stop a running watcher
  status             Show watcher status (running/stopped, log summary)
  touch              Refresh the sentinel keepalive timer

Options:
  --timeout <secs>   Inactivity timeout in seconds (default: 3600)
  --foreground       Run watcher in foreground (for debugging)

Environment:
  SPECWATCH_TIMEOUT  Override default timeout (seconds)
USAGE
}

check_fswatch() {
  if ! command -v fswatch >/dev/null 2>&1; then
    echo "specwatch: fswatch is not installed." >&2
    echo "" >&2
    echo "Install with:" >&2
    echo "  brew install fswatch     # macOS (recommended)" >&2
    echo "  apt install fswatch      # Debian/Ubuntu" >&2
    echo "  cargo install fswatch    # via Rust" >&2
    echo "" >&2
    echo "fswatch uses macOS FSEvents for efficient, kernel-level file monitoring." >&2
    return 1
  fi
}

log_header() {
  {
    echo "# Specwatch log — repo: $(basename "$REPO_ROOT")"
    echo "# Scanned: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
  } > "$LOG_FILE"
}

# --- Stale reference scanner ---
# Extracts markdown links [text](path) pointing to local files, checks existence,
# and suggests corrections using artifact ID extraction.

scan_stale_refs() {
  local mode="${1:-full}"   # "full" or "event" with artifact ID
  local event_id="${2:-}"   # artifact ID for event-driven mode (e.g., ADR-001)
  local found_stale=0

  log_header

  # Collect all markdown files in docs/
  local -a md_files=()
  while IFS= read -r -d '' f; do
    md_files+=("$f")
  done < <(find "$DOCS_DIR" -name '*.md' -print0 2>/dev/null)

  # Use Python to extract markdown links (handles balanced parens in filenames)
  # Output format: file\tline_num\tlink_target (one per line)
  local links_tmp
  links_tmp=$(mktemp /tmp/specwatch-links-XXXXXX)

  python3 - "${md_files[@]}" > "$links_tmp" <<'PYEOF'
import re, sys

# Regex handles balanced parens: [text](path with (parens) inside)
link_re = re.compile(r'\[([^\]]*)\]\(((?:[^()\s]|\([^()]*\))+)\)')

for filepath in sys.argv[1:]:
    try:
        with open(filepath) as f:
            for line_num, line in enumerate(f, 1):
                for m in link_re.finditer(line):
                    target = m.group(2)
                    # Skip external URLs, anchors, mailto
                    if target.startswith(('http://', 'https://', 'mailto:', '#')):
                        continue
                    # Skip targets that can't be file paths (no / or . means no path separator or extension)
                    if '/' not in target and '.' not in target:
                        continue
                    print(f"{filepath}\t{line_num}\t{target}")
    except (OSError, UnicodeDecodeError):
        pass
PYEOF

  # Process extracted links
  while IFS=$'\t' read -r md_file line_num link_target; do
    local dir
    dir="$(dirname "$md_file")"

    # Strip any anchor from the path
    local clean_path="${link_target%%#*}"
    [ -z "$clean_path" ] && continue

    # Resolve relative to the file's directory
    local resolved_path
    resolved_path="$(cd "$dir" && realpath -q "$clean_path" 2>/dev/null || echo "")"

    # If realpath fails or file doesn't exist, it's stale
    if [ -z "$resolved_path" ] || [ ! -e "$resolved_path" ]; then
      # In event mode, only report if the link mentions the affected artifact
      if [ "$mode" = "event" ] && [ -n "$event_id" ]; then
        case "$link_target" in
          *"$event_id"*) ;;  # matches — continue to report
          *) continue ;;      # doesn't match — skip
        esac
      fi

      # Try to find the new location
      local suggested=""
      local artifact_id=""

      # Extract artifact ID from the path: (TYPE-NNN) or TYPE-NNN
      local paren_id_re='\(([A-Z]+-[0-9]+)\)'
      local bare_id_re='([A-Z]+-[0-9]+)'
      if [[ "$clean_path" =~ $paren_id_re ]]; then
        artifact_id="${BASH_REMATCH[1]}"
      elif [[ "$clean_path" =~ $bare_id_re ]]; then
        artifact_id="${BASH_REMATCH[1]}"
      fi

      if [ -n "$artifact_id" ]; then
        # Search for the file by artifact ID
        local found_file
        found_file="$(find "$DOCS_DIR" -name "*${artifact_id}*" -name "*.md" -not -name "list-*" 2>/dev/null | head -1)"
        if [ -n "$found_file" ]; then
          # Compute relative path from the source file's directory
          suggested="$(python3 -c "import os; print(os.path.relpath('$found_file', '$dir'))" 2>/dev/null || echo "$found_file")"
        fi
      fi

      # Write structured log entry
      local rel_source
      rel_source="${md_file#"$REPO_ROOT"/}"
      {
        echo "STALE ${rel_source}:${line_num}"
        echo "  broken: ${link_target}"
        if [ -n "$suggested" ]; then
          echo "  found: ${suggested}"
        else
          echo "  found: NONE"
        fi
        echo "  artifact: ${artifact_id:-UNKNOWN}"
        echo ""
      } >> "$LOG_FILE"
      found_stale=1
    fi
  done < "$links_tmp"

  rm -f "$links_tmp"

  if [ "$found_stale" -eq 0 ]; then
    # Clear the log if nothing is stale
    rm -f "$LOG_FILE"
    echo "specwatch: no stale references found."
  else
    local count
    count=$(grep -c '^STALE ' "$LOG_FILE" 2>/dev/null || echo 0)
    echo "specwatch: found ${count} stale reference(s). See ${LOG_FILE}"
  fi
  return $found_stale
}

# --- Sentinel management ---

touch_sentinel() {
  touch "$SENTINEL"
}

sentinel_age() {
  if [ ! -f "$SENTINEL" ]; then
    echo "999999"
    return
  fi
  local now
  now=$(date +%s)
  local mod
  mod=$(stat -f %m "$SENTINEL" 2>/dev/null || stat -c %Y "$SENTINEL" 2>/dev/null || echo "0")
  echo $(( now - mod ))
}

# --- Watcher lifecycle ---

is_running() {
  if [ -f "$PID_FILE" ]; then
    local pid
    pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
    # Stale PID file
    rm -f "$PID_FILE"
  fi
  return 1
}

stop_watcher() {
  if [ -f "$PID_FILE" ]; then
    local pid
    pid=$(cat "$PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null
      echo "specwatch: stopped watcher (PID $pid)."
    else
      echo "specwatch: watcher not running (stale PID file removed)."
    fi
    rm -f "$PID_FILE"
  else
    echo "specwatch: no watcher running."
  fi
}

show_status() {
  if is_running; then
    local pid
    pid=$(cat "$PID_FILE")
    local age
    age=$(sentinel_age)
    local remaining=$(( TIMEOUT_SECS - age ))
    [ "$remaining" -lt 0 ] && remaining=0
    echo "specwatch: running (PID $pid)"
    echo "  sentinel age: ${age}s"
    echo "  timeout in: ${remaining}s"
  else
    echo "specwatch: not running"
  fi

  if [ -f "$LOG_FILE" ]; then
    local count
    count=$(grep -c '^STALE ' "$LOG_FILE" 2>/dev/null || echo 0)
    echo "  stale refs in log: $count"
  else
    echo "  log: clean"
  fi
}

run_watcher() {
  local foreground="${1:-false}"

  check_fswatch || return 1

  if is_running; then
    local pid
    pid=$(cat "$PID_FILE")
    echo "specwatch: already running (PID $pid). Use 'specwatch.sh stop' first."
    return 1
  fi

  touch_sentinel

  if [ "$foreground" = "true" ]; then
    echo "specwatch: watching $DOCS_DIR (foreground, timeout=${TIMEOUT_SECS}s)"
    _watcher_loop
  else
    _watcher_loop &
    local pid=$!
    echo "$pid" > "$PID_FILE"
    echo "specwatch: started (PID $pid, timeout=${TIMEOUT_SECS}s)"
    echo "  log: $LOG_FILE"
    echo "  sentinel: $SENTINEL"
  fi
}

_watcher_loop() {
  # Write our PID if running in foreground (background case writes it in run_watcher)
  trap '_cleanup' EXIT INT TERM

  # Start fswatch in the background, collecting events
  local batch_file
  batch_file=$(mktemp /tmp/specwatch-batch-XXXXXX)

  fswatch -r "$DOCS_DIR" \
    --include '\.md$' \
    --exclude '.*' \
    --batch-marker=EOF \
    -0 2>/dev/null | while IFS= read -r -d '' event; do
    if [ "$event" = "EOF" ]; then
      # Process the batch: extract any artifact IDs from changed paths
      if [ -s "$batch_file" ]; then
        # Debounce: wait a moment for additional events
        sleep "$DEBOUNCE_SECS"

        # Extract artifact IDs from the changed file paths
        local ids=""
        local paren_id_re='\(([A-Z]+-[0-9]+)\)'
        local bare_id_re='([A-Z]+-[0-9]+)'
        while IFS= read -r changed_path; do
          if [[ "$changed_path" =~ $paren_id_re ]]; then
            ids="${ids:+$ids }${BASH_REMATCH[1]}"
          elif [[ "$changed_path" =~ $bare_id_re ]]; then
            ids="${ids:+$ids }${BASH_REMATCH[1]}"
          fi
        done < "$batch_file"

        # Run scan (event-driven if we found IDs, full otherwise)
        if [ -n "$ids" ]; then
          for id in $ids; do
            scan_stale_refs "event" "$id" >/dev/null 2>&1 || true
          done
        else
          scan_stale_refs "full" >/dev/null 2>&1 || true
        fi
      fi
      : > "$batch_file"  # clear for next batch
    else
      echo "$event" >> "$batch_file"
    fi

    # Check sentinel age
    local age
    age=$(sentinel_age)
    if [ "$age" -ge "$TIMEOUT_SECS" ]; then
      echo "specwatch: inactivity timeout (${age}s >= ${TIMEOUT_SECS}s). Shutting down." >&2
      break
    fi
  done

  rm -f "$batch_file"
}

_cleanup() {
  rm -f "$PID_FILE"
  # Kill any fswatch children
  jobs -p 2>/dev/null | xargs -r kill 2>/dev/null || true
}

# --- Main dispatch ---

cmd="${1:-watch}"
shift 2>/dev/null || true

case "$cmd" in
  watch)
    foreground=false
    while [ $# -gt 0 ]; do
      case "$1" in
        --timeout) TIMEOUT_SECS="$2"; shift 2 ;;
        --foreground) foreground=true; shift ;;
        *) echo "specwatch: unknown option: $1" >&2; exit 1 ;;
      esac
    done
    run_watcher "$foreground"
    ;;
  scan)
    scan_stale_refs "full"
    ;;
  stop)
    stop_watcher
    ;;
  status)
    show_status
    ;;
  touch)
    touch_sentinel
    echo "specwatch: sentinel refreshed."
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    echo "specwatch: unknown command: $cmd" >&2
    usage >&2
    exit 1
    ;;
esac
