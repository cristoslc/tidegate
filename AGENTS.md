# AGENTS.md — Tidegate

Reference architecture for data-flow enforcement in AI agent deployments. Tidegate maps what it takes to prevent an AI agent from leaking sensitive data — through a topology where every data path from the agent passes through an enforcement boundary.

**This is a reference architecture, not a deployable product.** Documentation is the primary artifact. Any code is exploratory — proof-of-concept work that tests architectural assumptions. See [VISION-000](docs/vision/Active/(VISION-000)-Reference-Architecture/(VISION-000)-Reference-Architecture.md).

See `docs/vision/` for product vision, `docs/threat-model/` for threat model.

## Directory structure

```
docs/
├── vision/                # Product vision (VISION-NNN)
├── epic/                  # Epics (EPIC-NNN)
├── spec/                  # Agent specs (SPEC-NNN)
├── persona/               # User personas (PERSONA-NNN)
├── adr/                   # Architecture Decision Records (ADR-NNN)
├── research/              # Research spikes (SPIKE-NNN)
├── journey/               # User journeys (JOURNEY-NNN)
└── threat-model/          # Attack scenarios, defense mapping, scorecard
```

## Conventions

**Security**: never commit secrets. Fail-closed on all error paths.

**Shell**: POSIX sh, not bash. Must work in Alpine.

**Docker** (when implementing): pin base image versions, `read_only: true`, `cap_drop: [ALL]`, `no-new-privileges`, non-root user, `HEALTHCHECK` in every Dockerfile.

<!-- swain governance — do not edit this block manually -->

## Skill routing

When the user wants to create, plan, write, update, transition, or review any documentation artifact (Vision, Journey, Epic, Story, Agent Spec, Spike, ADR, Persona, Runbook, Bug) or their supporting docs (architecture overviews, competitive analyses, journey maps), **always invoke the swain-design skill**. This includes requests like "write a spec", "let's plan the next feature", "create an ADR for this decision", "move the spike to Active", "add a user story", "create a runbook", "file a bug", or "update the architecture overview." The skill contains the artifact types, lifecycle phases, folder structure conventions, relationship rules, and validation procedures — do not improvise artifact creation outside the skill.

**For all task tracking and execution progress**, use the **swain-do** skill instead of any built-in todo or task system. This applies whether tasks originate from swain-design (implementation plans) or from standalone work. The swain-do skill bootstraps and operates the external task backend — it will install the CLI if missing, manage fallback if installation fails, and translate abstract operations (create plan, add task, set dependency) into concrete commands. Do not use built-in agent todos when this skill is available.

## Pre-implementation protocol (MANDATORY)

Implementation of any SPEC artifact (Epic, Story, Agent Spec, Spike) requires a swain-do plan **before** writing code. Invoke the swain-design skill — it enforces the full workflow.

## Issue Tracking

This project uses **bd (beads)** for all issue tracking. Do NOT use markdown TODOs or task lists. Invoke the **swain-do** skill for all bd operations — it provides the full command reference and workflow.

<!-- end swain governance -->
