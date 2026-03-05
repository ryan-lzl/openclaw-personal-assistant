# Coding Task Packet Template

Ticket: TXXX  
Owner: PM agent  
Date: YYYY-MM-DD

## Goal
One paragraph describing the desired end state.

## Scope
- In scope:
- Out of scope:

## Acceptance criteria
1. Criterion 1
2. Criterion 2
3. Criterion 3

## Constraints
- Runtime/tooling constraints:
- File ownership constraints:
- Safety constraints:

## Web Search
Web Search: off
Web Search Model: minimax-m2.5:cloud

Allowed values:
- `off` (default; local-only execution)
- `optional` (use search only if needed)
- `required` (must use search; wrapper expects a `:cloud` model)

`Web Search Model` is optional when `Web Search` is `off`/`optional`.
When `Web Search: required`, wrapper auto-switches to `Web Search Model` (or env `WEB_SEARCH_CLOUD_MODEL`) if `CLAUDE_MODEL` is local.
The delegation skill (`.claude/skills/openclaw-delegate/SKILL.md`) enforces search behavior during execution.

## Subagent instruction (MANDATORY)
Subagents Min: 2  
Subagents Max: 10

Rules:
- both fields are required by `scripts/run_claude_task.sh` and enforced by the delegation skill
- values must be integers in the range `2..10`
- `Subagents Min` must be `<= Subagents Max`

Create subagents to parallelize:
1. Map relevant entrypoints and code paths
2. Locate tests and define the test run plan
3. Catalog conventions/patterns used in this repo

## Implementation notes
- Important files:
- Suggested approach:
- Risks:

## Deliverables
- Files expected to change:
- Tests expected to run:
- Docs expected to update:
