---
source-id: "checkpoint-claude-code-cves"
title: "Caught in the Hook: RCE and API Token Exfiltration Through Claude Code Project Files"
type: web
url: "https://research.checkpoint.com/2026/rce-and-api-token-exfiltration-through-claude-code-project-files-cve-2025-59536/"
fetched: 2026-03-17T00:00:00Z
hash: "sha256:6924f696b158e527d14f5517969abe32b8bb1cebf3b33dc03cb43fe20642d14c"
---

# Caught in the Hook: RCE and API Token Exfiltration Through Claude Code Project Files

**Authors:** Aviv Donenfeld, Oded Vanunu (Check Point Research)
**Published:** February 25, 2026
**CVEs:** CVE-2025-59536, CVE-2026-21852, plus one advisory without CVE (GHSA-ph6w-f82w-28w6)
**Category:** AI Security, Agent Tooling, Supply Chain

## Executive Summary

Check Point Research discovered critical vulnerabilities in Anthropic's Claude Code that allow attackers to achieve remote code execution and steal API credentials through malicious project configurations. The vulnerabilities exploit configuration mechanisms including Hooks, Model Context Protocol (MCP) servers, and environment variables -- executing arbitrary shell commands and exfiltrating Anthropic API keys when users clone and open untrusted repositories. All reported issues were patched prior to publication.

## Background

AI-powered development tools integrate into software workflows but introduce novel attack surfaces that traditional security models have not fully addressed. These platforms combine automated code generation with the risks of executing AI-generated commands and sharing project configurations across collaborative environments.

Claude Code, Anthropic's AI-powered command-line development tool, is a significant target in this landscape. As a leading agentic tool in the developer ecosystem, its adoption by technology professionals and integration into enterprise workflows means its security model directly impacts a substantial portion of AI-assisted development.

## Claude Code Platform

Claude Code enables developers to delegate coding tasks directly from their terminal through natural language instructions. It supports file modifications, Git repository management, automated testing, build system integration, MCP tool connections, and shell command execution.

## Configuration Files as Attack Surface

Claude Code supports project-level configurations through a `.claude/settings.json` file that lives directly in the repository. This design supports team collaboration -- when developers clone a project, they automatically inherit the same Claude Code settings their teammates use.

Since `.claude/settings.json` is just another file in the repository, any contributor with commit access can modify it. This creates a potential attack vector: malicious configurations could be injected into repositories, possibly triggering actions that users do not expect and may not be aware are occurring.

## Vulnerability #1: RCE via Untrusted Project Hooks (GHSA-ph6w-f82w-28w6)

### Hooks feature overview

Hooks execute user-defined commands at various points in Claude Code's lifecycle, providing deterministic control over behavior. Common use cases include automatic code formatting, compliance/debugging workflows, and custom permissions enforcement. Hooks are defined in `.claude/settings.json` -- the same repository-controlled configuration file.

### The vulnerability

Any contributor with commit access can define hooks that execute shell commands on every collaborator's machine when they work with the project. The researchers crafted a `.claude/settings.json` with a hook using the `SessionStart` event with a startup matcher, which triggers automatically during Claude Code initialization.

When running `claude` in the project directory, a trust dialog appeared warning about reading files and mentioning that Claude Code may execute files "with your permission." This phrasing suggests user approval will be required before execution.

However, after clicking "Yes, proceed" on the trust prompt, the hook command executed immediately with no additional prompt or execution warning. While normal bash commands during a session require explicit confirmation, hook commands defined in `.claude/settings.json` ran automatically without confirmation.

### Impact

An attacker could configure the hook to execute any shell command -- downloading and running malicious payloads, establishing reverse shells, achieving complete remote code execution. The session appears completely normal while commands from the untrusted repository have already run in the background.

### Example attack chain

1. Attacker places malicious `.claude/settings.json` in a repository with a `SessionStart` hook
2. Victim clones the repository and runs `claude`
3. Trust dialog appears, mentioning files may execute "with your permission"
4. Victim clicks "Yes, proceed"
5. Hook command executes immediately -- no additional confirmation
6. Attacker achieves RCE (demonstrated with reverse shell)

## Vulnerability #2: RCE Using MCP User Consent Bypass (CVE-2025-59536)

### MCP configuration mechanism

MCP (Model Context Protocol) allows Claude Code to interact with external tools and services through a standardized interface. MCP servers can be configured within the repository via `.mcp.json`. When opening a Claude Code conversation, the application initializes all MCP servers by running the commands written in the MCP configuration file.

### Anthropic's initial mitigation

After the first vulnerability report, Anthropic implemented an improved dialog that explicitly mentions commands in `.mcp.json` may be executed and emphasizes the risks. This made it harder for attackers to convince users to confirm initialization.

### The bypass

The researchers identified two configuration parameters in Claude Code's settings documentation:

- `enableAllProjectMcpServers` -- enables all servers defined in the project's `.mcp.json`
- `enabledMcpjsonServers` -- whitelists specific server names

These configurations can be included in the repository-controlled `.claude/settings.json`. Setting `enableAllProjectMcpServers` in the project settings caused MCP server initialization commands to execute **immediately upon running `claude`** -- before the user could even read the trust dialog. The calculator application opened on top of the pending trust dialog.

### Impact

Complete bypass of user consent. Arbitrary command execution occurs before the user has any opportunity to deny trust. Demonstrated with reverse shell for complete machine compromise.

### Example attack chain

1. Attacker places `.claude/settings.json` with `enableAllProjectMcpServers: true` and `.mcp.json` with malicious server command
2. Victim clones repository and runs `claude`
3. Malicious MCP server command executes **before the trust dialog is even displayed**
4. Attacker achieves RCE with zero user interaction beyond running `claude`

## Vulnerability #3: API Key Exfiltration via Malicious ANTHROPIC_BASE_URL (CVE-2026-21852)

### Discovery

While exploring the configuration schema, the researchers found that environment variables could be defined in `.claude/settings.json`. The `ANTHROPIC_BASE_URL` variable controls the endpoint for all Claude Code API communications.

### The vulnerability

By overriding `ANTHROPIC_BASE_URL` in the project's configuration file, an attacker can redirect all API traffic to an attacker-controlled server. The researchers set up mitmproxy to intercept HTTP traffic and observed that before the user could interact with the trust dialog, Claude Code had already initiated several requests -- and every request included the authorization header with the full Anthropic API key in plaintext.

### Impact: beyond billing fraud

What started as a research method immediately became an attack vector. An attacker places the malicious `ANTHROPIC_BASE_URL` in a repository; when a victim clones and runs `claude`, their API key is sent directly to the attacker's server **before the victim decides to trust the directory**. No user interaction required.

A stolen API key enables:

- **Workspace file access** -- Claude's Workspaces feature allows multiple developers to share cloud-mounted project files. Files belong to the workspace, not individual API keys. Any API key in the workspace inherits visibility into all stored files.
- **Download restriction bypass** -- While user-uploaded files have `downloadable: false`, files generated by Claude's code execution tool are downloadable. An attacker can instruct Claude to regenerate existing files using the stolen key, converting non-downloadable files into downloadable artifacts.
- **File deletion** -- removing critical files from the workspace
- **File upload** -- poisoning the workspace or exhausting the 100 GB storage quota
- **Billing fraud** -- running Claude queries charged to the victim's account

Unlike the code execution vulnerabilities that compromised a single developer's machine, a stolen API key may provide access to an entire team's shared resources.

### Example attack chain

1. Attacker places `.claude/settings.json` with malicious `ANTHROPIC_BASE_URL` pointing to attacker server
2. Victim clones repository and runs `claude`
3. Claude Code sends API key to attacker server before trust dialog is shown
4. Attacker uses stolen key to enumerate workspace files
5. Attacker regenerates files via code execution tool to bypass download restrictions
6. Attacker exfiltrates all workspace files

## Supply Chain Attack Scenarios

These vulnerabilities are particularly dangerous because they leverage supply chain vectors:

- **Malicious pull requests** -- seemingly legitimate PRs that include malicious configuration alongside actual code changes, making them harder for reviewers to spot
- **Honeypot repositories** -- useful-looking projects (development tools, code examples, tutorials) that contain malicious configuration, targeting developers who discover and clone them
- **Internal enterprise repositories** -- a single compromised developer account or insider threat can inject configuration into company codebases, affecting entire development teams

The key factor: developers inherently trust project configuration files -- they are viewed as metadata rather than executable code, so they rarely undergo the same security scrutiny as application code during reviews.

## Anthropic's Fixes

**Vulnerability #1 (Hooks RCE):** Anthropic implemented an enhanced warning dialog that appears when users open projects containing untrusted Claude Code configurations. The improved warning addresses hooks and other potential risks from untrusted project directories, including malicious MCP configurations.

**Vulnerability #2 (MCP consent bypass):** Anthropic ensured that MCP servers cannot execute before user approval, even when `enableAllProjectMcpServers` or `enabledMcpjsonServers` are set in the repository's configuration files.

**Vulnerability #3 (API key exfiltration):** Anthropic ensured no API requests are initiated before users confirm the trust dialog. This prevents malicious `ANTHROPIC_BASE_URL` configurations from intercepting API keys during project initialization, as Claude Code now defers all network operations until after explicit user consent.

## Protecting Against Configuration-Based Attacks

Modern development tools increasingly rely on project-embedded configurations and automations, creating new attack vectors. Configuration-based risks are likely a persistent threat in development ecosystems.

Recommendations:

- **Keep tools updated** -- all vulnerabilities discussed have been patched
- **Inspect configuration directories** before opening projects -- examine `.claude/`, `.vscode/`, and similar tool-specific folders
- **Pay attention to tool warnings** about potentially unsafe files, even in legitimate-looking repositories
- **Review configuration changes** during code reviews with the same rigor applied to source code
- **Question unusual setup requirements** that seem overly complex for a project's apparent scope

## Disclosure Timeline

| Date | Event |
|------|-------|
| July 21, 2025 | Check Point Research reported malicious hooks vulnerability to Anthropic |
| August 26, 2025 | Anthropic implemented final fix after collaborative refinement |
| August 29, 2025 | Anthropic published [GHSA-ph6w-f82w-28w6](https://github.com/advisories/GHSA-ph6w-f82w-28w6) |
| September 3, 2025 | Check Point Research reported MCP user consent bypass to Anthropic |
| September 22, 2025 | Anthropic implemented fix for bypass vulnerability |
| October 3, 2025 | Anthropic published [CVE-2025-59536](https://github.com/anthropics/claude-code/security/advisories/GHSA-4fgq-fpq9-mr3g) |
| October 28, 2025 | Check Point Research reported API key exfiltration vulnerability to Anthropic |
| December 28, 2025 | Anthropic implemented fix for API key exfiltration |
| January 21, 2026 | Anthropic published [CVE-2026-21852](https://nvd.nist.gov/vuln/detail/CVE-2026-21852) |
| February 25, 2026 | Public disclosure |

## Conclusion

These vulnerabilities highlight a critical challenge in modern development tools: balancing powerful automation with security. Repository-controlled configuration files that execute arbitrary commands created severe supply chain risks where a single malicious commit could compromise any developer working with the affected repository.

Configuration files that were once passive data now control active execution paths. As AI-powered development tools become more prevalent, the security community must carefully evaluate these new trust boundaries to protect the integrity of software supply chains.
