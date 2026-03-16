---
source-id: "002"
title: "Practical Security Guidance for Sandboxing Agentic Workflows and Managing Execution Risk"
type: web
url: "https://developer.nvidia.com/blog/practical-security-guidance-for-sandboxing-agentic-workflows-and-managing-execution-risk/"
fetched: 2026-03-15T00:00:00Z
hash: "sha256:pending"
---

# Practical Security Guidance for Sandboxing Agentic Workflows and Managing Execution Risk

**Published:** 2026-01-30
**Author:** Rich Harang, Principal Security Architect at NVIDIA (NVIDIA AI Red Team)
**Source:** NVIDIA Technical Blog

AI coding agents enable developers to work faster by streamlining tasks and driving automated, test-driven development. However, they also introduce a significant, often overlooked, attack surface by running tools from the command line with the same permissions and entitlements as the user, making them computer use agents, with all the risks those entail.

The primary threat to these tools is that of indirect prompt injection, where a portion of the content ingested by the LLM driving the model is provided by an adversary through vectors such as malicious repositories or pull requests, git histories with prompt injections, `.cursorrules`, CLAUDE/AGENT.md files that contain prompt injections or malicious MCP responses. Such malicious instructions to the LLM can result in it taking attacker-influenced actions with adverse consequences.

Manual approval of actions performed by the agent is the most common way to manage this risk, but it also introduces ongoing developer friction, requiring developers to repeatedly return to the application to review and approve actions. This creates a risk of user habituation where they simply approve potentially risky actions without reviewing them.

## Mandatory controls

Based on the NVIDIA AI Red Team's experience, the following mandatory controls mitigate the most serious attacks achievable with indirect prompt injection:

### Network egress controls

Blocking network access to arbitrary sites prevents exfiltration of data or establishing a remote shell without additional exploits. Network connections created by sandbox processes should not be permitted without manual approval. Tightly scoped allowlists enforced through HTTP proxy, IP, or port-based controls reduce user interaction and approval fatigue. Limiting DNS resolution to designated trusted resolvers to avoid DNS-based exfiltration is also recommended.

### Block file writes outside of the active workspace

Writing files outside of an active workspace is a significant risk. Files such as `~/.zshrc` are executed automatically and can result in both RCE and sandbox escape. URLs in various key files, such as `~/.gitconfig` or `~/.curlrc`, can be overwritten to redirect sensitive data to attacker-controlled locations.

Write operations must be blocked outside of the active workspace at an OS level.

### Block writes to configuration files

Many agentic systems permit the creation of extensions that include executable code. "Hooks" may define shell code to be executed on specific events. MCP servers using an stdio transport define shell commands required to start the server. Claude Skills can include scripts, code, or helper functions that run as soon as the skill is called.

Application-specific configuration files must be protected from any modification by the agent, with no user approval of such actions possible. Direct, manual modification by the user is the only acceptable modification mechanism.

## Why enforce at OS level?

Application-level controls are insufficient. They can intercept tool calls and arguments before execution, but once control passes to a subprocess, the application has no visibility into or control over the subprocess. Attackers often use indirection -- calling a more restricted tool through a safer, approved one -- as a common way to bypass application-level controls. OS-level controls, like macOS Seatbelt, work beneath the application layer to cover every process in the sandbox.

## Recommended controls

### Full virtualization

Many sandbox solutions (macOS Seatbelt, Windows AppContainer, Linux Bubblewrap, Dockerized dev containers) share the host kernel, leaving it exposed to any code executed within the sandbox. Because agentic tools often execute arbitrary code by design, kernel vulnerabilities can be directly targeted.

Run agentic tools within a fully virtualized environment isolated from the host kernel at all times, including VMs, unikernels, or Kata containers.

### Prevent reads from files outside the workspace

Unrestricted read access exposes information of value to an attacker, enabling enumeration and exploration of the user's device, secrets, and intellectual property.

- Use enterprise-level denylists to block reads from highly sensitive paths.
- Limit allowlist external reads to what is strictly necessary, ideally permitting reads only during sandbox initialization.
- Block all other reads outside the workspace unless manually approved.

### Approval caching is dangerous

Approvals should never be cached or persisted. Allow-once / run-many is not an adequate control. Each potentially dangerous action should require fresh user confirmation.

### Secret injection

Sandbox environments should rely on explicit secret injection to scope credentials to the minimum required for a given task, rather than inheriting the full set of host environment credentials.

- Start the sandbox with a simple or empty credential set.
- Inject required secrets based only on the specific task, ideally via a credential broker that provides short-lived tokens on demand.

### Sandbox lifecycle management

Long-running sandbox environments can accumulate artifacts: downloaded dependencies, generated scripts, cached credentials, IP from previous projects.

- **Ephemeral sandboxes:** Environments that exist only for the duration of a task.
- **Explicit lifecycle management:** Periodically destroying and recreating the sandbox in a known-good state.

## Tiered implementation

- Enterprise-level denylists that cannot be overridden by user-level allowlists or manual approval decisions.
- Allow read-write access within the agent's workspace (except configuration files) without user approval.
- Permit specific allowlisted operations that may be required for proper functionality.
- Assume default-deny for all other actions, permitting case-by-case user approval.
