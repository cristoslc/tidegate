# Moat and Agent Sandboxing — Research Synthesis

## Key Findings

### Network-layer credential injection is the core pattern

All three approaches (Moat, Docker Sandboxes, Anthropic's sandboxed bash) inject credentials at the network layer rather than exposing them to the agent process [majorcontext-moat](#majorcontext-moat), [docker-credentials](#docker-credentials). A TLS-intercepting proxy on the host adds authentication headers to outbound requests transparently, so the agent's code never sees raw tokens [majorcontext-moat](#majorcontext-moat).

### Two boundaries are required: filesystem + network isolation

Effective sandboxing requires both filesystem isolation and network isolation [anthropic-sandboxing](#anthropic-sandboxing). Without network isolation, a compromised agent could exfiltrate sensitive files; without filesystem isolation, a compromised agent could escape the sandbox and gain network access [anthropic-sandboxing](#anthropic-sandboxing).

### OS-level primitives enforce restrictions

Anthropic's sandboxed bash uses Linux bubblewrap and MacOS seatbelt to enforce restrictions at the OS level [anthropic-sandboxing](#anthropic-sandboxing). Docker sandboxes use container isolation with the credential proxy on the host [docker-credentials](#docker-credentials). Kubernetes Agent Sandbox supports multiple backends including gVisor and Kata Containers [kubernetes-agent-sandbox](#kubernetes-agent-sandbox).

### Stored secrets in OS keychain are preferred over environment variables

Docker recommends storing secrets in the OS keychain via `sbx secret set` rather than environment variables [docker-credentials](#docker-credentials). The keychain encrypts credentials at rest and controls access, while environment variables are plaintext and visible to other processes [docker-credentials](#docker-credentials).

## Points of Agreement

### Agents should never see raw credentials

All sources agree: credentials should not be stored in environment variables or configuration files inside the sandbox VM [docker-credentials](#docker-credentials). The agent process should not have direct read access to tokens [majorcontext-moat](#docker-credentials).

### Prompt injection is the primary threat model

Anthropic explicitly designs sandboxing to prevent prompt-injected agents from stealing SSH keys or phoning home to attacker servers [anthropic-sandboxing](#anthropic-sandboxing). Moat's design assumes agents may be compromised or buggy and protects against credential exfiltration [majorcontext-moat](#majorcontext-moat).

### Fewer permission prompts improve both security and productivity

Constant approval requests lead to "approval fatigue" where users don't pay attention to what they're approving [anthropic-sandboxing](#anthropic-sandboxing). Sandboxing reduces permission prompts by 84% in Anthropic's internal usage by defining boundaries within which the agent can work freely [anthropic-sandboxing](#anthropic-sandboxing).

## Points of Disagreement / Alternative Approaches

### Container overhead vs. OS-level sandboxing

Moat and Docker use full container isolation (Docker, Apple containers, gVisor) [majorcontext-moat](#majorcontext-moat), [docker-credentials](#docker-credentials). Anthropic's sandboxed bash runtime avoids container overhead by using OS-level primitives directly [anthropic-sandboxing](#anthropic-sandboxing). Trade-off: containers provide stronger isolation but more overhead; OS-level sandboxing is lighter but may have different security guarantees.

### Global vs. per-sandbox secrets

Docker supports both global secrets (available to all sandboxes) and sandbox-scoped secrets [docker-credentials](#docker-credentials). Global secrets only apply when a sandbox is created, while sandbox-scoped secrets take effect immediately [docker-credentials](#docker-credentials). This is more of a design choice than a disagreement.

### Kubernetes as deployment target

Kubernetes Agent Sandbox targets Kubernetes deployments with a standardized CRD API [kubernetes-agent-sandbox](#kubernetes-agent-sandbox). Moat and Anthropic focus on local developer workflows. Different deployment contexts may require different isolation strategies.

## Gaps

### Performance benchmarks

None of the sources provide quantitative performance comparisons between container-based isolation (Moat, Docker) and OS-level sandboxing (Anthropic's bubblewrap/seatbelt approach).

### Escape resistance testing

No source describes penetration testing or red-team exercises validating that the sandboxing approaches actually prevent credential exfiltration under adversarial conditions.

### Multi-tenant considerations

The Kubernetes Agent Sandbox mentions multi-tenant deployments but doesn't detail how credential injection works when multiple agents from different tenants share cluster infrastructure.

### Audit and compliance

Moat mentions "hash-chained audit logs with cryptographic verification" and "proof bundles for compliance" [majorcontext-moat](#majorcontext-moat), but none of the sources detail what compliance frameworks (SOC2, HIPAA, etc.) these approaches satisfy.

### Cost of credential proxy failures

If the credential proxy fails or misbehaves, what happens? Do agents fail closed (can't make API calls) or fail open (calls go through unauthenticated)? None of the sources address failure modes.
