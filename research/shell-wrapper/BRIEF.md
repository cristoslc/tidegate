# Shell Wrapper Research Brief

## What we're building

A shell wrapper that runs inside the agent container and intercepts every command before execution. Its job is to prevent encryption-before-exfiltration — the attack where a skill reads sensitive data, encodes it, and sends the encoded blob through an allowed channel, defeating pattern-based scanning at the network boundary.

## How it fits in the architecture

```
agent runs a command (e.g., "python3 process.py transactions.csv")
  │
  ▼
shell wrapper (Layer 1, in-container)
  │
  ├── 1. Parse command line → identify file args, script source, redirections
  ├── 2. Read referenced files (transactions.csv) and script source (process.py)
  ├── 3. Send file contents to scanner as plain values
  ├── 4. Scanner returns: "transactions.csv contains credit card numbers"
  ├── 5. Analyze command: does it involve encoding/encryption/exfiltration?
  ├── 6. Correlate: sensitive input + encoding operation → DENY (exit 1 + stderr)
  │     or: no sensitive input / no encoding → ALLOW (execute command)
  │
  ▼
if allowed, command executes normally
  │
  ├── MCP tool calls still go through Tidegate gateway (Layer 2)
  └── HTTP calls still go through agent-proxy (Layer 3)
```

## Key design constraints

1. **Scanner interface**: The scanner receives `{value: "..."}` and returns `{allow: true/false, reason: "..."}`. It has no filesystem access, no network access, no side effects. The wrapper does all file reading and sends contents as values.

2. **Correlation logic lives in the wrapper**: The scanner just answers "is this text sensitive?" The wrapper determines "is this command dangerous?" and makes the final allow/deny decision.

3. **Framework-agnostic**: Must work with any agent framework (Claude Code, OpenClaw, Codex CLI). Operates at the OS level, not through framework-specific hooks.

4. **Agent is the driver**: No human is waiting for commands to complete. Latency from scanning is acceptable. No need to allowlist safe commands.

5. **Error code = shaped deny**: When the wrapper blocks a command, it exits with a non-zero error code and writes an explanation to stderr. The agent sees a failed command and adjusts.

## Research questions

### 1. Existing shell wrapper/command interception approaches
- Are there existing tools that intercept shell commands for security scanning before execution?
- How do container security tools (Falco, Sysdig, Tracee) intercept commands? Could their approaches be adapted?
- Are there shell-level sandboxing tools that allow/deny commands based on policy?
- How does `sudo` implement its command interception and policy evaluation? Relevant patterns?

### 2. Command parsing and file extraction
- What's the most reliable way to parse a shell command line to extract file arguments, redirections, and pipe sources?
- How do you handle: subshells `$(...)`, process substitution `<(...)`, here-docs, variable expansion?
- Are there existing shell parsers (libraries) that produce an AST from a command string?
- What about commands that don't reference files explicitly (e.g., `python3 -c "open('secret.txt').read()"`)?

### 3. Encoding/exfiltration detection in commands
- How do you reliably detect that a command involves encoding (base64, openssl, gzip, python base64 module)?
- What's the full set of encoding primitives to watch for in a Unix environment?
- How do you detect exfiltration intent (curl, wget, nc, python requests, etc.) in a command pipeline?
- Are there tools that classify shell commands by intent/risk?

### 4. Implementation approaches
- Replace the shell binary vs. PATH shimming vs. shell function interposition vs. LD_PRELOAD vs. seccomp/eBPF?
- What's the simplest approach that's hard to bypass from within the container?
- How does Docker's `--security-opt` interact with command interception?
- Can you use `bash`'s `PROMPT_COMMAND`, `DEBUG` trap, or `command_not_found_handle` for interception?
- What about wrapping the shell entrypoint in the container's Dockerfile?

### 5. Prior art in AI agent security
- Do any AI agent security tools intercept commands at the shell level (not just tool-call level)?
- How do existing sandboxed code execution environments (E2B, Modal, Daytona) handle command interception?
- Are there any research papers on command-level interception for AI agent safety?

### 6. Bypass resistance
- If the wrapper replaces `/bin/sh`, can a process inside the container call `/bin/bash` directly?
- How do you prevent `exec()` syscalls from bypassing the wrapper?
- What's the realistic bypass surface for each implementation approach?
- Is there a way to use Linux namespaces or seccomp filters to force all exec through the wrapper?
