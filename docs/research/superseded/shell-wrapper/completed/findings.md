# Shell Wrapper Research Findings

Research completed 2026-02-22 for the Tidegate project.

Covers all 6 question areas from the research brief at `research/shell-wrapper/BRIEF.md`.

---

## 1. Existing Shell Wrapper / Command Interception Approaches

### 1.1 Shell-Level Interception (DEBUG trap, bash-preexec)

**bash-preexec** (https://github.com/rcaloras/bash-preexec) is the de facto standard for intercepting commands before execution in bash. It implements `preexec` and `precmd` hooks (borrowed from zsh) using bash's `DEBUG` trap and `PROMPT_COMMAND`.

How it works technically:
- Sets `trap '__bp_preexec_invoke_exec "$_"' DEBUG` which fires before every simple command.
- Uses `shopt -s extdebug` which, critically, allows the DEBUG trap to **skip command execution** by returning a non-zero value. This is the key capability needed for a deny mechanism.
- The `$BASH_COMMAND` variable contains the command about to execute.
- Multiple preexec functions can be registered in a `preexec_functions` array.

Limitations for Tidegate:
- Only works when the process is running under bash (or zsh with native preexec).
- Does not intercept commands executed via direct `exec()` syscalls from compiled binaries.
- An agent could bypass it by invoking `/bin/bash --norc` or `exec()` directly.
- The DEBUG trap fires for every simple command within compound commands, not just top-level commands, which requires careful filtering (bash-preexec handles this).
- Performance: ~1ms overhead per command on modern hardware, which is negligible for our use case since the agent is the driver.

**Bash 5.3 PS0** (available since late 2024) provides a cleaner preexec mechanism through `PS0` prompt expansion, which runs before command execution in the current shell. This eliminates some of the contortions bash-preexec needs. However, PS0 cannot cancel command execution -- it only runs code before it.

**Zsh native preexec/precmd**: Zsh has built-in `preexec()` and `precmd()` hook functions. Combined with the DEBUG trap and `setopt ERR_EXIT`, zsh can both intercept and cancel commands. The zsh approach is cleaner than bash's.

### 1.2 Container Security Runtime Tools

**Falco** (https://github.com/falcosecurity/falco, CNCF graduated project):
- Intercepts system calls at the kernel level via eBPF probes (modern) or a kernel module (legacy).
- Monitors ~350 syscalls including `execve`, `open`, `connect`, etc.
- Rule-based detection engine written in YAML.
- **Detection only, not prevention**: Falco observes and alerts but does not block syscalls. It generates alerts when suspicious behavior is detected (e.g., a shell being spawned in a container, a binary being written to disk, base64 being executed).
- Relevant Falco rules that map to our use case: `Terminal shell in container`, `Launch Suspicious Network Tool in Container`, `Base64-encoded Data`, `Sensitive file open`.
- Architecture: eBPF program in kernel -> perf ring buffer -> userspace Falco process -> rule evaluation -> alert output.
- Requires privileged access to the host (runs as DaemonSet in Kubernetes, needs access to `/dev`, `/proc`, `/boot`, kernel headers).

**Tracee** (https://github.com/aquasecurity/tracee, Aqua Security):
- Similar to Falco: eBPF-based runtime security.
- More focused on forensics and event tracing than Falco.
- Can capture command arguments, file access patterns, network connections.
- Also detection-only, not prevention.

**Key insight**: Neither Falco nor Tracee can **block** commands before execution. They operate at the kernel level for observation. To actually prevent execution, you need either seccomp (kernel-level blocking) or an interception layer above the kernel (shell wrapper, LD_PRELOAD, etc.).

### 1.3 Userspace Command Interception Tools

**bear/intercept** (https://man.archlinux.org/man/bear-intercept.1.en):
- A build tool that intercepts command executions to generate compilation databases.
- Two modes: `preload` (LD_PRELOAD hooking of exec functions) and `wrapper` (interposes a wrapper binary).
- Reports executions over a gRPC interface.
- Not designed for security, but demonstrates two viable interception architectures.

**sudo** (relevant patterns):
- `sudo` itself uses a configuration-based policy engine (`/etc/sudoers`).
- The `noexec` directive in sudoers uses `LD_PRELOAD` to prevent executed programs from running further programs: it preloads `sudo_noexec.so` which replaces `execl`, `execle`, `execlp`, `exect`, `execv`, `execve`, `execvp`, `execvpe`, `fexecve`, and `system()` with stubs that return EACCES.
- This pattern is directly relevant: it shows how to use LD_PRELOAD to control what child processes can execute.

**fapolicyd** (Red Hat, https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/8/html/security_hardening/assembly_blocking-and-allowing-applications-using-fapolicyd_security-hardening):
- File Access Policy Daemon for RHEL.
- Controls execution of applications based on a user-defined policy.
- Uses `fanotify` kernel API to intercept file open/execute operations.
- Can enforce allow/deny decisions based on file trust, type, path, etc.
- Operates at the kernel level, requires root.
- Relevant as a model for file-access-based policy enforcement, though too heavyweight for our container use case.

### 1.4 Relevance to Tidegate

The most directly applicable approaches are:
1. **Shell replacement** (custom shell binary as `/bin/sh`) -- highest control
2. **bash-preexec / DEBUG trap** -- simplest if we control the shell environment
3. **LD_PRELOAD exec hooking** (sudo_noexec pattern) -- catches subprocess spawning

None of the container security tools (Falco, Tracee) can block commands; they only detect. The eBPF/seccomp approaches could block but operate at a different layer than what the brief describes.

---

## 2. Command Parsing and File Extraction

### 2.1 Shell Parser Libraries

**mvdan/sh** (Go, https://github.com/mvdan/sh, `mvdan.cc/sh/v3`):
- The gold standard for programmatic shell parsing. Full POSIX Shell, Bash, and mksh support.
- Produces a complete AST with typed nodes: `CallExpr`, `Redirect`, `CmdSubst`, `ProcSubst`, `BinaryCmd`, `IfClause`, `ForClause`, etc.
- The `syntax.Walk()` function allows traversal of the entire AST.
- Can identify: command names, arguments, redirections (`>`, `>>`, `<`, `2>`), pipe chains, subshells `$(...)`, process substitution `<(...)`, here-docs, here-strings, variable assignments, and arithmetic expressions.
- Available as an npm package `sh-syntax` (WASM-compiled), making it usable from TypeScript/Node.js.
- Latest version: v3.11.0 (2025).
- **This is the recommended parser for Tidegate's shell wrapper.**

Technical example of extracting file arguments:
```go
import "mvdan.cc/sh/v3/syntax"

f, _ := syntax.NewParser().Parse(strings.NewReader("python3 process.py transactions.csv"), "")
syntax.Walk(f, func(node syntax.Node) bool {
    if word, ok := node.(*syntax.Word); ok {
        // Extract literal value from word parts
    }
    return true
})
```

**bashlex** (Python, https://github.com/idank/bashlex):
- Python port of GNU bash's internal parser.
- Produces an AST from bash command strings.
- Supports complex constructs: process substitution, command substitution, pipelines, redirections.
- Used by `explainshell.com` for its parsing backend.
- Limitations: some complex parameter expansions (`${parameter#word}`) are taken literally.
- Good option if the wrapper is implemented in Python.

**Python `shlex`** (stdlib, https://docs.python.org/3/library/shlex.html):
- Simple lexical analysis compatible with bash/dash/sh.
- With `punctuation_chars=True`, handles `();<>|&` as token delimiters.
- Not a full parser -- cannot build an AST or understand nested structures.
- Useful for simple tokenization but insufficient for our needs (need to detect subshells, pipes, redirections).

**ShellCheck** (Haskell, https://github.com/koalaman/shellcheck):
- Static analysis tool for shell scripts with a full parser.
- Has a complete AST (`ShellCheck.AST` module) with types for every shell construct.
- Written in Haskell, which makes integration difficult unless used as an external process.
- Not designed as a library for other programs to call, though the AST is exposed.

**Oil Shell / OSH** (Python/C++, https://www.oilshell.org/):
- Full shell implementation with a principled parser.
- Uses Zephyr ASDL for AST definition (borrowed from CPython).
- Parses the "dialect of shell used in the wild" including bash extensions.
- The parser does single-pass, up-front parsing (unlike bash which parses dynamically).
- Potentially useful as a reference implementation, but heavy to integrate.

### 2.2 File Argument Extraction Strategy

For the Tidegate wrapper, command parsing needs to identify:

1. **Explicit file arguments**: `cat secret.txt`, `python3 script.py data.csv`
2. **Redirections**: `command > output.txt`, `command < input.txt`
3. **Pipe sources**: `cat secret.txt | base64` (first command reads a file)
4. **Script source code**: For `python3 script.py`, read `script.py` to understand what it does
5. **Inline code**: `python3 -c "open('secret.txt').read()"` -- requires language-specific analysis

Recommended approach:
- Use `mvdan/sh` (via `sh-syntax` npm/WASM package) to parse the command into an AST.
- Walk the AST to extract: (a) command names, (b) positional arguments that look like file paths, (c) redirected files, (d) here-doc content.
- For arguments that look like file paths, check if they exist on the filesystem.
- For commands like `python3`, `node`, `ruby` with a script file argument, read the script source.
- For inline code (`-c` flags), extract the code string and perform static analysis on it.

### 2.3 The Hard Cases

**Subshells and command substitution**: `$(cat secret.txt)` or `` `cat secret.txt` `` -- the AST from `mvdan/sh` explicitly represents these as `CmdSubst` nodes, so they are parseable.

**Process substitution**: `diff <(cat file1) <(cat file2)` -- represented as `ProcSubst` nodes in the AST.

**Variable expansion**: `FILE=secret.txt; cat $FILE` -- static parsing cannot resolve variable values. This is a fundamental limitation. However, for our threat model (AI agent generating commands), the agent typically generates self-contained commands rather than relying on previously-set variables.

**Inline code**: `python3 -c "import base64; base64.b64encode(open('data.csv','rb').read())"` -- requires parsing the embedded Python. For the wrapper, treating `-c` arguments of known interpreters as code to be analyzed (scanning for file operations and encoding patterns) is feasible.

**Commands that don't reference files explicitly**: These cannot be caught by filename extraction alone. The wrapper should also analyze the command structure for encoding/exfiltration patterns (see section 3).

---

## 3. Encoding/Exfiltration Detection in Commands

### 3.1 Encoding Primitives in Unix

A comprehensive catalog of encoding tools available in a typical Unix/container environment:

**Binary-to-text encoders**:
| Tool | Description | Detection signature |
|------|------------|-------------------|
| `base64` | Standard Base64 encoding/decoding | Command name in pipeline |
| `base32` | Base32 encoding (more inflated than base64) | Command name |
| `openssl base64` | OpenSSL's built-in base64 | `openssl` with `base64` subcommand |
| `openssl enc` | Symmetric encryption (aes-256-cbc, etc.) | `openssl` with `enc` subcommand |
| `uuencode`/`uudecode` | Legacy Unix encoding | Command name |
| `xxd` | Hex dump / reverse hex dump | Command name, especially with `-p` (plain) flag |
| `od` | Octal dump (can output hex) | Command name with `-x` or `-A x` flags |
| `hexdump` | Hex dump utility | Command name |

**Compression tools** (compression + encoding defeats pattern scanning):
| Tool | Description |
|------|------------|
| `gzip`/`gunzip` | Standard compression |
| `bzip2`/`bunzip2` | Block compression |
| `xz`/`unxz` | LZMA compression |
| `zstd` | Zstandard compression |
| `lz4` | Fast compression |
| `tar` | Archive (often combined with compression: `-z`, `-j`, `-J`) |
| `zip`/`unzip` | ZIP archive |

**Encryption tools**:
| Tool | Description |
|------|------------|
| `openssl rsautl` | RSA encryption |
| `openssl pkeyutl` | Public key operations |
| `gpg`/`gpg2` | GNU Privacy Guard |
| `age` | Modern encryption tool |
| `ccrypt` | File encryption |

**Language-level encoding** (harder to detect, appears in inline code):
| Pattern | Language | Example |
|---------|----------|---------|
| `base64.b64encode` | Python | `python3 -c "import base64; ..."` |
| `Buffer.from(...).toString('base64')` | Node.js | `node -e "..."` |
| `Base64.encode64` | Ruby | `ruby -e "..."` |
| `[Convert]::ToBase64String` | PowerShell | `pwsh -c "..."` |
| `encode('base64')` | Perl | `perl -e "..."` |

**Exfiltration channels** (commands that send data to external destinations):
| Tool | Description |
|------|------------|
| `curl` | HTTP client |
| `wget` | HTTP client |
| `nc`/`ncat`/`netcat` | Raw TCP/UDP |
| `socat` | Socket relay |
| `ssh`/`scp`/`sftp` | Secure shell transfer |
| `rsync` | Remote sync |
| `ftp` | FTP client |
| `python3 -c "import requests"` | Python HTTP |
| `python3 -c "import urllib"` | Python HTTP |
| `python3 -c "import socket"` | Python raw socket |
| `node -e "require('http')"` | Node.js HTTP |
| `dig`/`nslookup`/`host` | DNS (can exfiltrate via DNS queries) |
| `ping` | ICMP (data in payload) |

### 3.2 Existing Detection Approaches

**Splunk detection rules** (https://research.splunk.com/):
- `Linux Decode Base64 to Shell`: Detects `base64 -d` piped to `sh` or `bash`.
- `Linux Obfuscated Files or Information Base64 Decode`: Detects `base64 -d` or `base64 --decode` in command lines.
- `Linux Auditd Base64 Decode Files`: Monitors auditd for base64 decode operations.
- These are regex-based pattern matching on command-line strings, suitable for adaptation.

**Elastic detection rules** (https://github.com/elastic/detection-rules):
- `defense_evasion_base64_decoding_activity.toml`: ESQL rule detecting unusual base64 activity on Linux.
- Monitors `process.name` and `process.command_line` for base64 patterns.
- Considers context: is this a security tool, a known admin script, or unusual activity?

**Google Cloud SCC** (`Defense Evasion: Base64 Encoded Shell Script Executed`):
- Detects processes with base64-encoded shell scripts as arguments.
- Signals attempt to encode binary data for transfer to ASCII-only command lines.

**MITRE ATT&CK mapping**:
- T1027 (Obfuscated Files or Information) -- base64 encoding for evasion.
- T1048 (Exfiltration Over Alternative Protocol) -- DNS, ICMP exfiltration.
- T1041 (Exfiltration Over C2 Channel) -- curl/wget to external servers.
- T1132 (Data Encoding) -- encoding data before exfiltration.

### 3.3 Detection Strategy for Tidegate

The wrapper should implement a **two-dimensional analysis**:

**Dimension 1 -- Sensitive Input Detection**: Parse the command to identify what data it reads (files, stdin). Send those values to the scanner. If the scanner says "sensitive," proceed to Dimension 2.

**Dimension 2 -- Dangerous Operation Detection**: Classify the command by what it *does* with data:
- **Encoding**: `base64`, `xxd`, `openssl enc`, compression tools, language-level encoding.
- **Exfiltration**: `curl`, `wget`, `nc`, DNS tools, language-level network operations.
- **Encryption**: `openssl`, `gpg`, `age`.
- **Chaining**: Pipe chains that combine reading + encoding + sending.

**Correlation rule**: If sensitive data is detected AND the command involves encoding/encryption/exfiltration, DENY. Neither alone is sufficient -- agents legitimately read sensitive data (to operate on it) and legitimately use encoding tools (for non-sensitive data).

The detection should be implemented as a pattern-matching engine over the parsed AST, not over raw command strings. This avoids false positives from commands that *mention* encoding tools in arguments (e.g., `echo "use base64 to encode"`).

---

## 4. Implementation Approaches

### 4.1 Approach Comparison

| Approach | Interception Scope | Bypass Difficulty | Implementation Complexity | Container Compat |
|----------|-------------------|-------------------|--------------------------|------------------|
| Replace `/bin/sh` with custom binary | All shell invocations | Medium -- direct exec of other binaries | High (must faithfully proxy all shell behavior) | Excellent |
| PATH shimming | Commands in PATH | Low -- use absolute paths | Low | Excellent |
| Shell function interposition | Named commands in current shell | Low -- subshells don't inherit | Low | Good |
| `DEBUG` trap / bash-preexec | All commands in bash sessions | Medium -- run bash without trap | Low-Medium | Good |
| LD_PRELOAD exec hooking | All dynamically-linked exec calls | Medium -- static binaries bypass | Medium | Good |
| Seccomp-BPF | All syscalls in process tree | Very High -- kernel-level | High | Requires privileges |
| eBPF (Falco-style) | All syscalls on host | Very High -- kernel-level | Very High | Requires host access |
| AppArmor profile | All exec transitions | High -- kernel-level | Medium | Requires host AppArmor |
| Custom shell binary as entrypoint | All commands from agent | High within container | Medium-High | Excellent |

### 4.2 Detailed Analysis of Top Approaches

#### 4.2.1 Custom Shell Binary as Container Entrypoint (RECOMMENDED)

The approach:
- Build a small binary (Go or Rust) that acts as the shell for the agent container.
- Install it as `/bin/sh` (or whatever the agent's shell is) in the container image.
- Move the real shell to `/bin/sh.real` (or `/bin/bash.real`).
- The wrapper receives every command the agent framework sends to the shell.
- It parses the command, performs analysis, and either executes it via the real shell or returns an error.

How it works:
```
Agent framework calls: /bin/sh -c "python3 process.py data.csv"
                           |
                    Our wrapper binary (/bin/sh)
                           |
                    Parse command, extract files, scan
                           |
                  ALLOW: exec /bin/sh.real -c "python3 process.py data.csv"
                  DENY:  exit 1, write explanation to stderr
```

Advantages:
- Framework-agnostic: works with any agent that spawns shell commands.
- Container-native: no special kernel features or host access needed.
- The wrapper sees the complete command string before execution.
- Cannot be bypassed by the agent calling a different shell (if we control which shells exist in the container).

Implementation details:
- Must handle all shell invocation patterns: `/bin/sh -c "command"`, `/bin/sh script.sh`, `/bin/sh` (interactive), `/bin/sh -e -c "command"`.
- Must faithfully pass through stdin/stdout/stderr.
- Must preserve exit codes from the real shell.
- Must handle signals (SIGTERM, SIGINT, etc.) and forward them.
- The binary should be statically compiled (Go is ideal for this) so it has no runtime dependencies.

#### 4.2.2 LD_PRELOAD Exec Hooking (COMPLEMENTARY)

The approach:
- Create a shared library that hooks `execve()`, `execvp()`, `execl()`, etc.
- Load it via `/etc/ld.so.preload` (global preload, not an environment variable that can be cleared).
- On every exec call, inspect the command being executed and decide whether to allow it.

How it works:
- When any dynamically-linked program calls `execve()`, the hooked version runs first.
- The hook can read the executable path and arguments.
- If the command matches a dangerous pattern, return `EACCES` instead of executing.
- If allowed, call the real `execve()` via `dlsym(RTLD_NEXT, "execve")`.

This is exactly how `sudo_noexec.so` works. The sudo project provides a well-tested implementation of this pattern.

Limitations:
- **Does not work on statically-linked binaries**: Go and Rust programs bypass libc entirely and call `execve` as a raw syscall. Statically-linked busybox would also bypass.
- **Does not work on programs that make raw syscalls**: Even dynamically-linked programs can bypass by using the `syscall()` function directly.
- Container Alpine images use musl-libc, which may have different behavior than glibc.

Mitigation for Tidegate: In our controlled container, we know what binaries are installed. We can ensure no statically-linked shells or tools are present. The agent generates commands through the shell, which is dynamically linked.

#### 4.2.3 Seccomp-BPF with SECCOMP_RET_USER_NOTIF (STRONGEST, MOST COMPLEX)

Since Linux 5.0, seccomp supports `SECCOMP_RET_USER_NOTIF`, which forwards intercepted syscalls to a userspace supervisor process. This is used by container runtimes (LXD, CRI-O) to emulate syscalls.

How it would work for Tidegate:
- The container entrypoint sets up a seccomp filter that triggers `SECCOMP_RET_USER_NOTIF` on `execve` syscalls.
- A supervisor process (running inside or outside the container) receives notifications.
- The supervisor reads the `execve` arguments (program path, argv, envp) from `/proc/pid/mem`.
- The supervisor decides allow/deny and responds via `SECCOMP_IOCTL_NOTIF_SEND`.

**Critical caveat from the kernel developers** (Christian Brauner, seccomp maintainer): "The seccomp notify fd cannot be used to implement any kind of security policy in userspace." The reason is a TOCTOU race: between the time the supervisor reads `/proc/pid/mem` to check arguments and the time it responds, another thread could modify the memory. For string arguments like file paths, this is exploitable.

Despite this warning, for our use case (single-threaded agent shell commands), the TOCTOU risk is much lower than in a general-purpose container. The agent is generating commands through a shell, not a multi-threaded program racing to modify exec arguments.

Advantages:
- Kernel-level interception: cannot be bypassed from userspace.
- Works for all binaries (static, dynamic, raw syscalls).
- Inherits across fork/exec.

Disadvantages:
- Requires Linux >= 5.0, runc >= 1.1.0.
- Complex implementation.
- TOCTOU concerns (mitigatable in our single-threaded use case).
- Requires the container runtime to support seccomp notify (Docker supports this).

#### 4.2.4 Bubblewrap (bwrap)

Claude Code's own sandbox implementation uses bubblewrap on Linux (https://www.sambaiz.net/en/article/547/). Bubblewrap creates isolated namespaces using `clone(2)` with flags like `CLONE_NEWNET`, `CLONE_NEWPID`, etc.

Key capabilities:
- `--unshare-net`: Creates a new empty network namespace (no network access).
- `--ro-bind`: Mount host paths as read-only in the sandbox.
- `--dev`, `--proc`: Create minimal /dev and /proc.
- `--seccomp`: Apply seccomp filters.
- Very low overhead: ~3.7ms per invocation (100 iterations in 0.374s), vs Docker's ~11ms.

Bubblewrap is a building block, not a command interception tool. It creates the isolation environment within which the wrapper would run.

### 4.3 Bash Mechanisms (DEBUG trap, PROMPT_COMMAND, command_not_found_handle)

**DEBUG trap with extdebug** (most capable):
```bash
shopt -s extdebug
trap 'wrapper_check "$BASH_COMMAND"' DEBUG
# If wrapper_check returns non-zero, the command is skipped
```
- `$BASH_COMMAND` contains the command about to be executed.
- With `extdebug`, a non-zero return from the DEBUG trap prevents execution.
- This is exactly how bash-preexec works under the hood.

**PROMPT_COMMAND**: Runs before the prompt is displayed (after command completion), not before command execution. Not useful for interception.

**command_not_found_handle**: Only fires for commands not found in PATH. Not useful for intercepting known commands.

**PS0** (bash >= 4.4): Expanded and displayed after reading a command but before execution. Cannot prevent execution -- only runs code.

Recommendation: The DEBUG trap with extdebug is the only bash-native mechanism that can both inspect and cancel commands.

### 4.4 Docker Security Options

- `--security-opt seccomp=profile.json`: Apply a custom seccomp profile. Can block syscalls but not make complex decisions about command arguments.
- `--security-opt apparmor=profile`: Apply an AppArmor profile. Can restrict which executables can run and which files can be accessed.
- `--security-opt no-new-privileges`: Prevents the process from gaining new privileges via setuid, setgid, or capabilities. Important for our container.
- `--cap-drop ALL`: Drop all Linux capabilities. Prevents the agent from loading kernel modules, changing network config, etc.

These are complementary to the shell wrapper, not a replacement. They provide defense-in-depth.

---

## 5. Prior Art in AI Agent Security

### 5.1 AI Agent Sandbox Platforms

**E2B** (https://e2b.dev/, open-source):
- Cloud infrastructure for AI agent sandboxes.
- Uses Firecracker microVMs for hardware-level isolation.
- Each sandbox is a dedicated microVM with its own kernel.
- The agent SDK sends code to the sandbox API, which executes it and returns results.
- **No command-level interception**: E2B isolates at the VM boundary, not at the command level. The agent can run anything inside its sandbox.
- Startup time: ~150ms per sandbox.
- Session limit: 24 hours (Pro plan).

**Modal** (https://modal.com/):
- Uses gVisor for syscall-level isolation.
- gVisor's Sentry intercepts all ~237 syscalls and handles them in userspace.
- The sandboxed process never makes direct syscalls to the host kernel.
- Modal's sandbox pricing is 3x standard container rates.
- **No command-level policy**: gVisor ensures isolation, not command inspection.

**Daytona** (https://daytona.io/):
- Docker containers with optional Kata Containers or Sysbox.
- Sub-90ms sandbox creation.
- Persistent workspaces (files, dependencies persist across sessions).
- **No command interception**: Isolation is at the container boundary.

**Docker Sandboxes** (https://www.docker.com/blog/docker-sandboxes-run-claude-code-and-other-coding-agents-unsupervised-but-safely/):
- MicroVM-based isolation specifically for coding agents (Claude Code, Codex, Gemini, Kiro).
- Interactive bash shell inside an isolated microVM.
- Network isolation with proxy-managed API keys.
- "Shell sandbox" type provides an interactive bash environment.
- **No per-command interception**: The sandbox provides an environment, not a command filter.

### 5.2 Claude Code's Own Sandboxing

**Claude Code sandbox-runtime** (https://code.claude.com/docs/en/sandboxing, https://www.anthropic.com/engineering/claude-code-sandboxing):
- Two boundaries: filesystem isolation + network isolation.
- Linux implementation uses **bubblewrap** (`bwrap`).
- `--unshare-net` for network isolation.
- Filesystem restrictions via OS primitives (bubblewrap bind mounts).
- Network access through a Unix socket to a host-side proxy with domain allowlists.
- Static analysis before executing bash commands to identify risky operations.
- **Relevant insight**: Claude Code does perform some static analysis of commands before execution, suggesting Anthropic considers command-level inspection valuable. However, this is prompt-level static analysis, not a shell wrapper.

### 5.3 Academic Research

**"Your AI, My Shell" (arXiv:2509.22040, 2025)**:
- Studies prompt injection attacks on agentic AI coding editors (Cursor, VS Code with Copilot).
- Documents attacks where AI agents execute `rm -rf /`, exfiltrate data, or modify system files.
- Finds that external resources (.cursor/rules, GitHub templates) can inject malicious instructions.
- Does not propose command-level interception but documents the threat model.

**"Takedown: How It's Done in Modern Coding Agent Exploits" (arXiv:2509.24240, 2025)**:
- Documents real exploits against coding agents.
- References RedCode benchmark for risky code execution by code agents.
- Covers data exfiltration through prompt injection in GitHub Copilot Chat.

**Agent Security Bench (ASB, ICLR 2025)**:
- Benchmarks agent security across multiple dimensions.
- Uses the ReAct framework for LLM agent evaluation.
- Documents prompt injection, goal hijacking, and tool misuse.

**"AI Agents Under Threat" (ACM Computing Surveys, 2024)**:
- Survey of key security challenges for AI agents.
- ToolEmu identifies failures where agents execute risky commands without permission.
- Documents interception of observations and tool usage.

**"Systems Security Foundations for Agentic Computing" (IACR ePrint 2025/2173)**:
- Discusses prompt injection leading to data exfiltration.
- References CVE-2025-32711 (EchoLeak) against Microsoft Copilot.
- Argues for security boundaries between agent and system resources.

**Key finding**: No academic paper proposes shell-level command interception for AI agent security. The field focuses on prompt-level defenses, sandbox isolation, and tool-call-level policy (which is what Tidegate's gateway already does). Shell-level interception to prevent encoding-before-exfiltration is a novel contribution.

### 5.4 Related Commercial Tools

**Lakera Guard** (https://www.lakera.ai/): Prompt injection detection, not command interception.

**LLMGuard** (AAAI 2024): Guards against unsafe LLM behavior at the prompt/response level.

**Blaxel**: Agent hosting with complete sandboxing of agent, model, and tools. Still isolation-based, not command-inspection-based.

None of these tools operate at the shell command level. They all operate at either the prompt level, the tool-call level, or the infrastructure isolation level. Tidegate's shell wrapper would fill a gap that no existing tool addresses.

---

## 6. Bypass Resistance

### 6.1 Shell Replacement Bypasses

If the wrapper replaces `/bin/sh`:

| Bypass Attempt | Can the Agent Do This? | Mitigation |
|---------------|----------------------|-----------|
| Call `/bin/bash` directly | Yes, if bash exists | Remove all shell binaries except the wrapper. Symlink `/bin/bash` -> wrapper too. |
| Call `/usr/bin/python3 -c "import os; os.system('...')"` | Yes | Python's `os.system()` calls `/bin/sh -c` under the hood, which goes through our wrapper. `os.exec*()` variants that bypass the shell need additional mitigation. |
| Call `exec()` syscall directly from a compiled binary | Yes, if a suitable binary exists | Remove unnecessary binaries from container. Use LD_PRELOAD or seccomp as additional layer. |
| Compile a new binary and run it | Only if compiler exists | Don't include compilers in the container image. |
| Download a binary and run it | Only if curl/wget exist and network allows | Network isolation prevents downloads. Remove curl/wget from container. |
| Use busybox applets | Only if busybox exists | Don't include busybox in the container. |
| Use `perl -e "exec(...)"` | Only if perl exists | Minimize installed interpreters. |

### 6.2 LD_PRELOAD Bypasses

| Bypass | Description | Mitigation |
|--------|------------|-----------|
| Static binaries | Statically-linked executables ignore LD_PRELOAD entirely | Don't include static binaries in container |
| Raw syscalls | Use `syscall(SYS_execve, ...)` directly from C/assembly | Can't be mitigated with LD_PRELOAD alone |
| Clear `LD_PRELOAD` env var | Unset it before exec | Use `/etc/ld.so.preload` instead (file-based, harder to clear) |
| `dlopen` + `dlsym` | Load and call the real `execve` directly | The hooked version still intercepts the libc wrapper |
| Go programs | Go runtime bypasses libc for syscalls | No mitigation via LD_PRELOAD |
| Rust programs (musl) | Statically linked with musl | Same as static binaries |

### 6.3 Seccomp-BPF Bypass Resistance

Seccomp filters, once installed, apply to the process and all its descendants (across `fork()` and `execve()`). They cannot be removed from within the sandboxed process.

| Bypass Attempt | Possible? | Notes |
|---------------|-----------|-------|
| Unload the seccomp filter | No | Filters are immutable once loaded |
| Ptrace to modify syscall after seccomp check | No (since Linux 4.8) | Ordering fixed: ptrace runs before seccomp |
| Call a blocked syscall | No | Kernel returns error before execution |
| Modify memory after seccomp reads args (TOCTOU) | Theoretically yes | Only matters for pointer arguments read from `/proc/pid/mem` |
| Use vDSO to bypass | Limited | Only a few simple syscalls (gettime, etc.) are vDSO |

Seccomp is the strongest mechanism. Its main limitation is that **BPF filters can only inspect syscall number and register arguments**, not pointer-dereferenced data (like file paths in `execve`). To make decisions based on file paths, you need `SECCOMP_RET_USER_NOTIF` + `/proc/pid/mem` reading, which has TOCTOU concerns.

### 6.4 AppArmor Bypass Resistance

AppArmor profiles restrict which executables can be run and which files can be accessed. They operate at the kernel's LSM (Linux Security Module) hooks.

| Feature | Description |
|---------|------------|
| Path-based policy | Can restrict which executables can be launched (e.g., only `/bin/sh.wrapper` can exec `/bin/sh.real`) |
| Inheritance | Child processes inherit the AppArmor profile |
| Cannot be disabled from within | Profile is enforced by the kernel |
| Exec transitions | Can specify that when binary X runs binary Y, Y gets a specific restricted profile |

AppArmor is complementary to the shell wrapper. It can ensure that even if the agent tries to execute a binary directly (bypassing the wrapper), the execution is blocked unless it goes through the approved path.

### 6.5 Defense-in-Depth Strategy

No single mechanism is sufficient. The recommended approach is layered:

1. **Layer 1 -- Shell replacement**: Custom binary as `/bin/sh` (and all other shell paths). Catches all agent-generated shell commands. This is where the scanning and analysis logic lives.

2. **Layer 2 -- Minimal container image**: Remove all unnecessary binaries, interpreters, compilers, and static executables. The agent should only have the tools it needs. Use a minimal base image (distroless or custom Alpine).

3. **Layer 3 -- LD_PRELOAD exec hooking** (via `/etc/ld.so.preload`): Catches exec calls from dynamically-linked binaries that bypass the shell. Acts as a second interception point.

4. **Layer 4 -- Seccomp profile**: Restrict the syscall surface to only what the agent needs. Block `ptrace`, `process_vm_writev`, and other dangerous syscalls. Optionally use `SECCOMP_RET_USER_NOTIF` on `execve` for strongest guarantees.

5. **Layer 5 -- Network isolation**: Already part of Tidegate's architecture (agent-net with egress-proxy). Even if encoding succeeds, the encoded data can only leave through approved channels.

6. **Layer 6 -- AppArmor profile** (if available on host): Restrict exec transitions to ensure only the wrapper can invoke the real shell.

---

## Synthesis: Recommended Implementation Approach

### Architecture

The shell wrapper should be a **statically-compiled Go binary** that replaces `/bin/sh` (and other shell paths) in the agent container. Go is chosen because:

1. **Static compilation**: No runtime dependencies (important for minimal containers).
2. **Excellent process management**: `os/exec` package handles stdin/stdout/stderr/signals/exit codes correctly.
3. **mvdan/sh integration**: The best shell parser library is written in Go, providing native AST access without WASM/FFI.
4. **Performance**: Single binary, fast startup (<5ms), negligible overhead.
5. **Cross-compilation**: Easy to build for linux/amd64 and linux/arm64.

### Wrapper Flow

```
1. Agent framework sends: /bin/sh -c "python3 process.py transactions.csv"
2. Wrapper receives the command string.
3. Parse command into AST using mvdan/sh.
4. Extract: command name (python3), script file (process.py), data file (transactions.csv).
5. Read file contents: process.py source code, transactions.csv data.
6. Send file contents to scanner: {value: "4532-xxxx-xxxx-1234,...", field: "transactions.csv"}
7. Scanner returns: {allow: false, reason: "contains credit card numbers"}
8. Analyze command for encoding/exfiltration patterns:
   - Check AST for known encoding tools in pipeline
   - Check script source for encoding imports/operations
   - Check for network operations
9. Correlate: sensitive input (transactions.csv) + encoding risk (none detected)
   -> ALLOW (even though data is sensitive, no encoding/exfiltration detected)

   OR: sensitive input + base64 in pipeline -> DENY
10. If ALLOW: exec /bin/sh.real -c "python3 process.py transactions.csv"
11. If DENY: exit 1, write explanation to stderr
```

### Scanner Interface

The wrapper communicates with the scanner (Tidegate's existing scanner subprocess) via stdin/stdout JSON:

```json
// Request
{"value": "4532-1234-5678-9012\n4716-9876-5432-1098\n...", "field": "transactions.csv"}

// Response
{"allow": false, "reason": "contains credit card numbers (Luhn-valid patterns)"}
```

The scanner is stateless and has no filesystem or network access (per existing Tidegate design).

### Encoding/Exfiltration Classification

Implement a pattern-matching engine over the parsed AST:

```go
type CommandRisk struct {
    HasSensitiveInput  bool
    HasEncodingOp      bool   // base64, xxd, openssl enc, etc.
    HasCompressionOp   bool   // gzip, xz, tar, etc.
    HasEncryptionOp    bool   // openssl, gpg, etc.
    HasExfiltrationOp  bool   // curl, wget, nc, etc.
    HasInlineCode      bool   // python -c, node -e, etc.
    EncodingDetails    string
    ExfiltrationDetails string
}
```

The correlation logic: `DENY if HasSensitiveInput AND (HasEncodingOp OR HasEncryptionOp OR (HasCompressionOp AND HasExfiltrationOp))`.

### Container Image Hardening

The agent container Dockerfile should:
1. Install the wrapper binary as `/bin/sh`, with the real shell at `/bin/sh.real`.
2. Symlink all common shell paths to the wrapper: `/bin/bash`, `/usr/bin/bash`, `/bin/dash`, etc.
3. Install `/etc/ld.so.preload` with an exec-hooking shared library as a second layer.
4. Remove unnecessary binaries: compilers, static executables, unnecessary interpreters.
5. Apply a restrictive seccomp profile that blocks `ptrace`, `process_vm_writev`, etc.
6. Set `read_only: true`, `no-new-privileges: true`, `cap_drop: ALL` (per existing Tidegate conventions).

### Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Go binary, not shell script | Shell scripts can be bypassed by invoking the interpreter directly. A binary is opaque. |
| mvdan/sh for parsing | Best-in-class shell parser, native Go, full AST with typed nodes. |
| Replace `/bin/sh` in container | Framework-agnostic: any agent that runs shell commands goes through the wrapper. |
| Correlation logic in wrapper, not scanner | Scanner is stateless and has no command context. The wrapper knows the full command structure. |
| Layered defense (wrapper + LD_PRELOAD + seccomp) | No single layer is bypass-proof. Layers compound difficulty. |
| Deny = exit 1 + stderr explanation | Consistent with the brief's "error code = shaped deny" design. Agent reads stderr and adjusts. |
| Scanner interface via JSON over stdin/stdout | Consistent with existing Tidegate scanner interface. No new protocol needed. |

### What This Does NOT Solve

1. **Multi-step attacks**: The agent reads sensitive data in one command (allowed), stores it in a variable, then encodes and exfiltrates in a separate command. The wrapper sees each command independently and cannot correlate across commands.

   Mitigation: Track file reads across commands within a session. If a file was scanned as sensitive, flag subsequent commands that encode anything (even from memory).

2. **Steganographic encoding**: The agent could encode data in ways that don't use standard encoding tools (e.g., custom Python code that implements base64 from scratch).

   Mitigation: For inline code (`-c` flags), perform basic static analysis for encoding patterns. This is imperfect but raises the bar significantly.

3. **Timing-based exfiltration**: Encode data in the timing of HTTP requests or the length of responses.

   Mitigation: Out of scope for the shell wrapper. Network-level monitoring would be needed.

4. **Agent operating entirely through tool calls**: If the agent never runs shell commands and only uses MCP tool calls, the shell wrapper never fires.

   Mitigation: The Tidegate gateway already handles tool-call-level scanning. The shell wrapper is a complementary layer for agents that execute shell commands.

### Implementation Phases

**Phase 1**: Core wrapper binary (Go). Replace `/bin/sh`. Parse commands with mvdan/sh. Extract file arguments. Call scanner. Allow/deny based on scanner response alone (no encoding detection yet).

**Phase 2**: Add encoding/exfiltration detection. Build the AST pattern-matching engine for encoding tools, compression tools, and exfiltration channels. Implement correlation logic.

**Phase 3**: Add inline code analysis. For `python3 -c`, `node -e`, etc., parse the embedded code for encoding and file-access patterns.

**Phase 4**: Defense-in-depth layers. Add LD_PRELOAD exec hooking. Harden the container image. Add seccomp profile. Document bypass resistance.
