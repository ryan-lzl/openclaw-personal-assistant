---
name: openclaw-delegate
description: Execute an OpenClaw coding task packet from a file path. Use for PM-to-coding delegation in this repository.
argument-hint: "<packet.md>"
disable-model-invocation: true
---

# OpenClaw Delegation Skill

This skill is invoked manually as:

`/openclaw-delegate <packet.md>`

Packet path argument (first arg): `$0`

## 1) Load and validate packet

1. Read `$0` as a file path relative to the current working directory unless absolute.
2. If the file is missing or unreadable, stop and report an actionable error.
3. Parse and enforce these required packet fields:
   - `Web Search: off|optional|required`
   - `Subagents Min: 2..10`
   - `Subagents Max: 2..10` and must be `>= Subagents Min`
4. If validation fails, stop and return only the validation errors.

## 2) Respect launcher context

The launcher may include a block named `Launcher context (validated by wrapper)` in the user prompt.

If present, treat these launcher-provided values as authoritative over conflicting packet text:
- Effective Web Search Mode
- Subagents Min / Subagents Max

## 3) Subagent-first execution protocol

Before implementation, create between `Subagents Min` and `Subagents Max` subagents to parallelize:
1. Relevant files and entrypoints
2. Test mapping and run strategy
3. Existing repo patterns/conventions

Each subagent must return concise findings first. Then synthesize findings into an implementation plan and execute.

## 4) Web search policy

Use the effective web-search mode (launcher override if present, otherwise packet value):
- `off`: do not use external web search.
- `optional`: use web search only when task depends on external or time-sensitive facts.
- `required`: use web search for all external or time-sensitive facts.

When web search is used, include source URLs and retrieval date (`YYYY-MM-DD`) in the final answer.

## 5) Delivery contract

At completion, return:
1. Summary of what changed
2. Files changed
3. Commands run
4. Test results
5. Risks or follow-ups
