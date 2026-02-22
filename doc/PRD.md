# PRD.md — Product Requirements & Feature Inventory

> Canonical reference for what exists, where it lives, and how it works.

---

## Table of contents
1. Architecture overview
2. Agent roles
3. Approval & security model
4. Task handoff protocol
5. Model/runtime inventory
6. Optional search
7. Logs & observability
8. Roadmap

---

## 1) Architecture overview

### Components
- PM brain:
  - OpenClaw (agent framework) + vLLM serving `nemotron-3-nano-30b-a3b`
- Coding stack:
  - Claude Code (repo tool) + Ollama serving `qwen3-coder`
- Optional search:
  - Brave API or self-hosted search (SearXNG)

### Data flows
1) User ↔ PM brain (chat + planning)
2) PM brain → (approval gate) → `scripts/run_claude_task.sh`
3) Claude Code ↔ repo (read/edit/execute) + subagents (parallel tasks)
4) Claude Code → summary back to PM brain (results + next steps)

---

## 2) Agent roles

### PM brain (OpenClaw + vLLM)
Responsibilities:
- mission intake
- decomposition into tickets
- acceptance criteria
- decision log / tradeoffs
- delegation to coding agent (approval required)

Non-goals:
- direct code edits
- running arbitrary commands

### Coding agent (Claude Code + Ollama)
Responsibilities:
- explore repo
- implement changes
- run tests / commands
- iterate until acceptance criteria met
- spawn subagents when parallel exploration helps

---

## 3) Approval & security model

- Host execution is gated via OpenClaw exec approvals (policy + allowlist + user approval).
- Only allow running a wrapper script:
  - `scripts/run_claude_task.sh`

---

## 4) Task handoff protocol

PM must:
- produce a “Coding Task Packet”
- include explicit instruction: “Create subagents …”
- ask user: “Approve delegating Ticket #N?”

Coding agent must:
- spawn 2–10 subagents when tasks can parallelize:
  - file search
  - test mapping
  - API route tracing
- return: summary, file list touched, commands run, test results.

(See `docs/HANDOFF_PROTOCOL.md`)

---

## 5) Model/runtime inventory

- PM brain model: `nemotron-3-nano-30b-a3b`
- Coding model: `qwen3-coder`

---

## 6) Optional search

Two modes:
1) No-cost: self-hosted search (recommended)
2) Paid: Brave Search API

---

## 7) Logs & observability
- vLLM server logs: container/stdout
- Ollama logs: systemd or container logs
- OpenClaw logs: gateway logs + tool invocations
- Claude Code logs: session output + optional transcript capture

---

## 8) Roadmap
- Add structured “task state” file: `memory/tasks.jsonl`
- Add automated “post-task report” markdown generator
- Add CI to validate repo changes and style rules
