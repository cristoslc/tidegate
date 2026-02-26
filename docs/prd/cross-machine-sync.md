# PRD: Cross-Machine Code and User Data Synchronization

**Status:** Draft
**Date:** 2026-02-26
**Source:** [cristoslc/202602-workstation@216d808](https://github.com/cristoslc/202602-workstation/commit/216d808a26cf3dc3eef1f71db8817eedd3ff9122)

---

## 1. Problem Statement

A developer working across 2–3 workstations (desktop, laptop, possibly macOS) needs two things that no single existing tool provides:

1. **User data sync** — Documents, Pictures, Music, Videos, and Downloads must stay in sync across machines with minimal manual intervention, conflict handling, and near-zero data loss risk.

2. **Code working-state transfer** — Uncommitted work (edits, new files, staged changes) must transfer between machines without requiring noisy WIP commits, and without corrupting git internals or garbling working trees when machines are on different branches.

### Why existing tools fail individually

| Tool | User data sync | Code sync |
|------|---------------|-----------|
| **Syncthing** | Good (P2P, real-time, versioning) | Breaks `.git/` internals; garbles working trees across branches |
| **Git push/pull** | N/A | Good for committed work; cannot transfer uncommitted changes |
| **Dropbox / cloud sync** | Works but not self-hosted | Same `.git/` corruption risks as Syncthing |
| **rsync** | One-shot only; no ongoing daemon | Manual; no conflict detection |
| **Unison** | Possible but no real-time daemon | Safe if `.git/` excluded, but needs branch-awareness to avoid cross-branch working tree garbling |

The core insight from the research: **user data and code repositories are fundamentally different sync problems** and require different solutions.

---

## 2. Goals

### Must Have (P0)

1. **One-time data migration**: Bulk-copy user data folders from an old machine to a new one after bootstrap, with resume capability, checksum verification, and non-destructive behavior (never delete destination files by default).

2. **Ongoing user data sync**: Keep Documents, Pictures, Music, Videos, and Downloads in continuous sync across 2–3 workstations via a self-hosted hub-and-spoke topology.

3. **Branch-aware code sync**: Transfer working tree state (including uncommitted changes) between machines, isolated by git branch name, without ever syncing `.git/` directories.

4. **Sleep/wake resilience**: When a laptop sleeps and another machine continues working, the waking machine catches up automatically (or with a single command).

5. **No git corruption**: `.git/` directories must never be synced between machines, under any configuration.

### Should Have (P1)

6. **Background polling for code sync**: Automatic periodic sync (every 5 minutes) plus wake-from-suspend triggers, eliminating the need for manual invocation in typical workflows.

7. **Pre-sleep push**: Push local working state to the hub before the machine suspends, so the next machine has the latest state immediately upon waking.

8. **Ansible-managed deployment**: All sync infrastructure (tools, configuration, services) deployable via existing Ansible roles and Make targets.

9. **Tailscale integration**: Use Tailscale IPs for NAT traversal when machines are behind different NATs (e.g., laptop on the road).

### Nice to Have (P2)

10. **Git post-checkout hook**: Auto-sync immediately on branch switch rather than waiting for the next timer interval.

11. **Stale branch pruning**: Periodic cleanup of server-side branch directories not modified in 30+ days.

12. **Per-repo sync overrides**: Allow individual repos to specify additional exclusion patterns (e.g., `.terraform`, `.vagrant`) via a `.wsync-ignore` file.

---

## 3. Non-Goals

- **Dotfile sync** — Managed by GNU Stow (already exists).
- **System configuration sync** — Managed by Ansible (already exists).
- **Secret management** — Managed by SOPS/age (already exists).
- **Git history sync** — Handled by git push/pull to Forgejo. This system only syncs working tree state.
- **Real-time collaborative editing** — This is not Google Docs. Only one person edits per machine at a time.
- **Cloud-hosted storage** — All infrastructure is self-hosted on the user's home server.
- **Untrusted-server encryption** — The hub server is self-hosted and trusted (same trust as SSH access).

---

## 4. Architecture

### 4.1 High-Level Topology

```
┌──────────┐         ┌──────────────┐         ┌──────────┐
│ Desktop  │         │  Hub Server  │         │  Laptop  │
│          │◄───────►│  (always-on) │◄───────►│          │
│ Syncthing│  LAN /  │  Syncthing   │  LAN /  │ Syncthing│
│  + wsync │ Tailscale│  + Unison   │ Tailscale│  + wsync │
└──────────┘         └──────────────┘         └──────────┘
     ▲                      ▲                       ▲
     │    User data:        │                       │
     │    Syncthing ◄───────┼───────► Syncthing     │
     │    (P2P via hub)     │         (P2P via hub) │
     │                      │                       │
     │    Code repos:       │                       │
     │    Unison ──────────►│◄──────── Unison       │
     │    (branch-keyed     │    (branch-keyed      │
     │     directories)     │     directories)      │
     └──────────────────────┴───────────────────────┘
```

### 4.2 User Data Sync: Syncthing Hub-and-Spoke

**Tool:** Syncthing (MPL-2.0, Go, P2P)

**Topology:** Star / hub-and-spoke. The hub (home server) is the always-on relay. Spokes (workstations) connect only to the hub, never to each other.

**Key design decisions:**

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Topology | Hub-and-spoke (not full mesh) | Serializes changes through hub, reduces conflict window to propagation delay (seconds on LAN). Simpler config for 2–3 devices. |
| Folder type | Send & Receive on all devices | Hub is a relay, not an authority. Bidirectional sync needed. |
| Introducer feature | Disabled | With only 2–3 spokes, manual device management is trivial. Introducer can undermine strict star topology by introducing spokes to each other. |
| Discovery | Disabled (global + local) | Fully private network. Static addresses via Tailscale IPs. |
| Relaying | Disabled (or private relay) | No public infrastructure. Self-hosted `strelaysrv` if remote access needed beyond Tailscale. |
| File versioning | Staggered on hub | Hub is canonical backup copy. Decaying retention (many recent, fewer old). |
| `.stignore` | Exclude `.git/`, build artifacts, OS metadata | Prevent git corruption, reduce noise. |

**Conflict handling:** Version-vector-based. Newer mtime wins, device ID tiebreaker. Conflict copies named `<file>.sync-conflict-<date>-<time>-<device>.<ext>` and synced to all devices. `maxConflicts=10` (default). For user data folders (Documents, Pictures, etc.), conflicts are rare — users typically work on one machine at a time.

### 4.3 Code Sync: Branch-Aware Unison

**Tool:** Unison 2.52+ (GPL-3.0, OCaml, bidirectional)

**Core idea:** Route working trees through the hub server using `<repo>/<branch>/` as the directory key. Two machines on the same branch converge to the same server directory. Machines on different branches sync to different directories. `.git/` never leaves the machine.

**Server-side layout:**

```
/srv/code-sync/
  <repo-name>/
    <branch>/
      <working tree files, excluding .git/>
```

**Why not Syncthing for code?** The Syncthing creator explicitly states: _"The answer to the topic question 'Can syncthing reliably sync local Git repos?' is definitely **no**."_ Even with `.git/` excluded, Syncthing garbles working trees when machines are on different branches — it sees branch-checkout file changes as normal edits and merges them, producing a hybrid working tree that matches no commit in the repository.

**Why Unison?** On-demand invocation (no daemon), rsync-like rolling-checksum delta transfer, best-in-class conflict resolution (interactive + auto modes), profile-based configuration, and SSH transport (pairs with Tailscale for NAT traversal).

### 4.4 One-Time Migration: rsync

**Tool:** rsync 3.2+ (via `ansible.posix.synchronize` or Make target)

**Key properties:** Non-destructive by default (no `--delete`), partial-file resume (`--partial-dir`), block-level delta transfer, full metadata preservation (`-ahAX`), checksum verification (always post-transfer), cross-platform (Linux ↔ macOS), first-class Ansible integration.

---

## 5. User Scenarios

### 5.1 Normal Workflow: Sequential Editing

1. Work on desktop (branch `main`), edit files, don't commit.
2. Background timer syncs desktop → hub every 5 minutes. Or: desktop suspends, pre-sleep service pushes to hub.
3. Walk to laptop. Open laptop (wake). Timer fires on wake → hub → laptop.
4. Working tree matches desktop's state. Continue editing.
5. Background timer syncs laptop → hub periodically.
6. Return to desktop. Wake triggers sync. Hub → desktop.

**No manual intervention required.** The `wsync` CLI exists for forcing immediate sync.

### 5.2 Branch Switching

1. Desktop on `main`, syncing to `hub:repo/main/`.
2. Desktop runs `git checkout feature-x`. Working tree changes.
3. Post-checkout hook (or next timer interval) syncs to `hub:repo/feature-x/`.
4. `hub:repo/main/` retains the last-synced `main` state.
5. Laptop (still on `main`) syncs with `hub:repo/main/` — unaffected.
6. If laptop also checks out `feature-x`, its next sync pulls from `hub:repo/feature-x/`, picking up desktop's changes.

### 5.3 New Machine Setup

1. Run `make bootstrap` — provisions OS, installs tools, deploys dotfiles.
2. Run `make data-pull SOURCE=old-machine` — rsync pulls user data folders.
3. Syncthing and wsync services start automatically via Ansible-deployed systemd units.
4. Ongoing sync begins.

### 5.4 Conflict Scenario (Code)

Rare, but possible if you edit the same file on two machines without syncing:

1. Desktop edits `src/app.py` on `main`. Does NOT sync.
2. Laptop edits `src/app.py` on `main`. Syncs to hub.
3. Desktop syncs. Unison detects conflict.
4. With `prefer = newer`: the more recent edit wins. Losing version preserved in backup.
5. Without `prefer`: Unison skips the file and reports the conflict. Run interactively to resolve.

---

## 6. Components

### 6.1 `wsync` Wrapper Script

**Location:** `shared/dotfiles/bin/wsync` (deployed via Stow)

**Interface:**

```
wsync              # sync all configured repos
wsync <repo>       # sync one repo by name
wsync --status     # show branch + last-sync time per repo
```

**Behavior:**

1. Walk configured code directories (`~/code/*/`), find git repos.
2. For each repo, read current branch (`git symbolic-ref --short HEAD`).
3. Sanitize branch name for filesystem (`/` → `__`).
4. Invoke Unison: local working tree ↔ `hub:/srv/code-sync/<repo>/<branch>/`.
5. Exclude `.git/`, `node_modules`, `__pycache__`, build artifacts, editor swap files.

**Configuration:**

- `WSYNC_HUB` env var (default: `hub`) — Tailscale hostname of hub server.
- `WSYNC_ROOT` env var (default: `/srv/code-sync`) — server-side base directory.
- `CODE_DIRS` — list of directories to scan for repos (default: `~/code`).
- Base Unison profile at `~/.unison/code-sync.prf` — shared settings, exclusion patterns.

### 6.2 Background Service (Linux)

**Units:** `~/.config/systemd/user/`

| Unit | Purpose |
|------|---------|
| `wsync.service` | Oneshot: runs `wsync` once per invocation |
| `wsync.timer` | Fires 30s after boot, then every 5 minutes. `Persistent=true` for wake-from-suspend catch-up. |
| `wsync-pre-sleep.service` | Runs `wsync` before suspend (`Before=sleep.target`) |

### 6.3 Background Service (macOS)

| Component | Purpose |
|-----------|---------|
| `com.user.wsync.plist` | launchd agent, fires every 300 seconds + at load |
| `sleepwatcher` (optional) | Runs `~/.wakeup` on resume from sleep |

### 6.4 Syncthing Configuration

Deployed via Ansible role. Key settings per device:

| Setting | Hub | Spoke |
|---------|-----|-------|
| Listening address | `tcp://0.0.0.0:22000` | `tcp://<hub-tailscale-ip>:22000` |
| Global Discovery | Disabled | Disabled |
| Local Discovery | Disabled | Disabled |
| Relaying | Disabled | Disabled |
| Peers | All spokes | Hub only |
| Folder type | Send & Receive | Send & Receive |
| File versioning | Staggered | None (hub is canonical) |

### 6.5 Hub Server Setup

**Requirements:** Always-on Linux server with SSH access and Unison 2.52+ installed. No special software — the server is a dumb file store for code sync and a Syncthing peer for user data sync.

**Directory structure:**

```
/srv/code-sync/           # Unison code sync (auto-created by wsync)
  <repo>/<branch>/        # Working tree snapshots
```

**Syncthing data:** Standard Syncthing data directory for user folder sync.

---

## 7. Exclusion Patterns

### 7.1 Syncthing `.stignore` (User Data)

```
// Git directories — never sync
.git

// Build artifacts
node_modules
__pycache__
*.pyc
build
dist
target

// OS metadata
(?d).DS_Store
(?d)Thumbs.db

// Editor artifacts
*.swp
*~
```

### 7.2 Unison `code-sync.prf` (Code Repos)

```
batch     = true
auto      = true
prefer    = newer
times     = true
perms     = 0

ignore = Path {.git}
ignore = Name {.DS_Store}
ignore = Name {._*}
ignore = Name {*.pyc}
ignore = Name {__pycache__}
ignore = Name {node_modules}
ignore = Name {.venv}
ignore = Name {venv}
ignore = Name {build}
ignore = Name {dist}
ignore = Name {target}
ignore = Name {.tox}
ignore = Name {.eggs}
ignore = Name {*.egg-info}
ignore = Name {.cache}
ignore = Name {*.swp}
ignore = Name {*~}
```

---

## 8. Risk Assessment

### 8.1 Technical Risks

| Risk | Severity | Likelihood | Mitigation |
|------|----------|------------|------------|
| Syncthing syncs `.git/` by accident | Critical | Low (`.stignore` configured by Ansible) | Ansible-deployed `.stignore` template; validation in smoke tests |
| Unison OCaml 5 silent corruption | Critical | Medium (if wrong binary used) | Pin Unison to OCaml 4.14 pre-built binaries via Ansible |
| Hub server unavailable | Medium | Low (always-on, UPS) | Fall back to git push/pull for committed work; uncommitted work stays local |
| Simultaneous edits on same file/branch | Medium | Low (sequential workflow) | `prefer = newer` auto-resolves; backup preserves losing version |
| Unison version mismatch client/server | Medium | Low | Pin 2.53.x everywhere via Ansible |
| Branch name collision after sanitization | Low | Very low | `__` delimiter is unlikely in branch names; document convention |
| Stale branch directories consume disk | Low | Medium | Periodic pruning cron (find dirs older than 30 days) |

### 8.2 Operational Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| User forgets to wait for sync before switching machines | Low | Background timer + wake trigger minimize staleness to <5 minutes |
| macOS lacks native wake trigger for launchd | Low | `sleepwatcher` via Homebrew, or accept 5-minute max staleness |
| Syncthing conflict files accumulate unnoticed | Medium | Periodic `find` for `.sync-conflict-*` files; consider monitoring script |
| Seafile macOS client crashes (documented on Ventura/Monterey) | N/A | Seafile not selected for this design; using Syncthing instead |

---

## 9. Implementation Plan

### Phase 1: One-Time Migration

1. Add `make data-pull SOURCE=hostname` and `make data-pull-dry` targets.
2. Ensure Homebrew rsync 3.2+ is installed on macOS (system rsync is 2.6.9).
3. SSH key authentication already provisioned by bootstrap.
4. Use Tailscale hostnames for machines behind NAT.

### Phase 2: User Data Sync (Syncthing)

1. Create `shared/roles/sync/` Ansible role.
2. Install Syncthing via apt (Linux) / Homebrew (macOS).
3. Enable systemd user service (Linux) / Homebrew service (macOS).
4. Template initial configuration via REST API or `config.xml`.
5. Deploy `.stignore` templates for user data folders.
6. Configure hub-and-spoke topology (hub address, disable discovery/relay).

### Phase 3: Code Sync (Unison)

1. Install Unison 2.53.x on all machines and hub via Ansible.
2. Create base Unison profile (`~/.unison/code-sync.prf`) via Ansible template.
3. Write `wsync` wrapper script; deploy to `shared/dotfiles/bin/` via Stow.
4. Set up hub directory (`/srv/code-sync/`); Ansible task on server role.
5. Deploy background services:
   - Linux: `wsync.service` + `wsync.timer` + `wsync-pre-sleep.service`
   - macOS: `com.user.wsync.plist` + optional `sleepwatcher`
6. Optional: git `post-checkout` hook for immediate sync on branch switch.
7. Optional: stale branch pruning cron job.

### Phase 4: Validation

1. Smoke test: sync a test repo between two machines, verify working tree integrity.
2. Branch isolation test: checkout different branches on two machines, verify no cross-contamination.
3. Sleep/wake test: suspend one machine, edit on the other, wake and verify sync.
4. Conflict test: edit same file on both machines without syncing, verify Unison conflict handling.
5. Migration test: `make data-pull-dry` against a test source.

---

## 10. Decision Log

| Decision | Choice | Alternatives Considered | Rationale |
|----------|--------|------------------------|-----------|
| User data sync tool | Syncthing | Seafile, Nextcloud, Unison, rclone bisync | P2P (no server dependency for sync engine), real-time daemon, built-in versioning, NAT traversal, active community. Seafile is better for pure sync perf but adds server complexity. |
| Code sync tool | Unison | Syncthing (`.git/` excluded), rsync, git push/pull | Only tool that provides bidirectional sync with conflict detection, on-demand invocation, and rsync-like delta transfer — without the always-on daemon overhead. Branch-keyed directories solve the cross-branch problem. |
| Migration tool | rsync | rclone, tar+ssh, Unison | Resume, delta, metadata preservation, Ansible-native. Clear winner on every criterion. |
| Syncthing topology | Hub-and-spoke | Full mesh | Fewer conflicts (serialized through hub), simpler config, hub doubles as backup. Single point of failure accepted (hub is always-on home server). |
| Syncthing introducer | Disabled | Enabled | Too few devices (2–3) to justify complexity. Introducer can undermine strict star topology. |
| Code sync branch isolation | Directory-keyed on server | Single directory with `.git/` excluded | Cross-branch working tree garbling is documented and unavoidable with single-directory sync. Directory isolation is the only safe approach. |
| Unison conflict policy | `prefer = newer` | No `prefer` (interactive), `prefer = <root>` | Sequential workflow makes simultaneous edits rare. `newer` auto-resolves with backup preservation. Interactive mode available for edge cases. |
| Forgejo role | Secondary (committed history + CI) | Primary (all code transfer) | Cannot transfer uncommitted work. Unison handles working-state transfer; Forgejo handles committed history, code review, and CI/CD. |

---

## 11. Open Questions

1. **Auto-discovery vs. config file for repos.** Should `wsync` auto-discover repos by walking `~/code/*/`, or use an explicit config file (`~/.config/wsync/repos`)? Auto-discovery is zero-config but may find repos you don't want to sync. Leaning toward auto-discovery with an opt-out `.wsync-ignore`.

2. **Conflict policy default.** `prefer = newer` is simple and works for sequential editing, but silently overwrites one version on simultaneous edits. The backup mechanism preserves the losing version. Is this acceptable, or should the default be no auto-resolution (skip + report)?

3. **Repo discovery depth.** Should the wrapper find nested repos (`~/code/org/repo/`)? One level is simple. Recursive adds complexity and may find submodules. Start with one level, make depth configurable?

4. **Server-side deduplication.** Multiple branches share most files. The server stores full copies. For small-to-medium repos this is fine. For very large repos, could use filesystem-level dedup (btrfs, ZFS). Worth the complexity?

5. **Syncthing vs. Seafile for user data.** The research evaluated both thoroughly. Seafile has superior sync performance (block-level CDC, 2–8x faster than rsync per USENIX FAST '18) but adds server complexity, has no macOS CLI, and requires manual garbage collection. Is the performance difference meaningful for typical user data folders (low write frequency, large files)?

---

## 12. References

- [Syncthing Hub-and-Spoke Deep Dive](https://github.com/cristoslc/202602-workstation/blob/216d808/docs/research/Active/sync-user-folders/syncthing-hub-spoke.md) — Topology configuration, conflict mechanics, folder types, operational tradeoffs
- [Syncthing + Git Repos Analysis](https://github.com/cristoslc/202602-workstation/blob/216d808/docs/research/Active/sync-user-folders/syncthing-git-repos.md) — Why Syncthing cannot sync git repos, failure modes, workarounds
- [Branch-Aware Unison Code Sync](https://github.com/cristoslc/202602-workstation/blob/216d808/docs/research/Active/sync-user-folders/unison-code-sync.md) — Design for `wsync`, background services, scenario walkthroughs
- [Sync User Folders README](https://github.com/cristoslc/202602-workstation/blob/216d808/docs/research/Active/sync-user-folders/README.md) — Tool comparison matrix, recommendations
- [Seafile macOS Clients](https://github.com/cristoslc/202602-workstation/blob/216d808/docs/research/Active/sync-user-folders/seafile-macos-clients.md) — Client version history, performance regressions
