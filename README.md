# OpenClaw Personal Assistant

## DGX Spark PM + Coding Agent Stack (OpenClaw + vLLM + Claude Code + Ollama)

A local, no-API-cost(ish) agent stack optimized for **repo-level issue fixing** and **PM-style planning**:

- **PM brain (planner/orchestrator):** OpenClaw → vLLM → `nemotron-3-nano-30b-a3b`
- **Coding agent (repo editor/executor):** Claude Code → Ollama → `qwen3-coder`
- **Search:** optional (Brave API or self-hosted search). Coding subagents prioritize repo exploration and local execution.

Key design goal: **The PM agent can talk to the coding agent**, but must ask for **your approval** before delegating. The coding agent can **spawn subagents** for parallel repo exploration when needed.

---

## Why this architecture?

### Separation of concerns
- The PM agent is great at: goals → plan → decomposition → task packets → acceptance criteria.
- The coding agent is great at: reading files, editing code, running tests, iterating.

### Safety by default
- Any host command execution is **approval-gated**.
- The PM agent is not allowed to directly mutate your repo. It must route changes through Claude Code.

---

## Repository layout
.
├── README.md
├── IDENTITY.md
├── SOUL.md
├── PRD.md
├── docs/
│ ├── DGX_SPARK_SETUP.md
│ ├── HANDOFF_PROTOCOL.md
│ └── SECURITY_MODEL.md
├── config/
│ ├── openclaw.example.json
│ ├── openclaw.tool-policy.example.json
│ └── models.example.md
└── scripts/
├── run_claude_task.sh
└── healthcheck.sh


---

## Quick start (high level)

1) Bring up vLLM server for the PM brain.
2) Bring up Ollama and pull `qwen3-coder`.
3) Configure OpenClaw to:
   - use vLLM as primary model
   - allow *only* `scripts/run_claude_task.sh` via exec approvals (everything else denied)
4) Use the **handoff protocol** to dispatch coding tasks (approval required).

See: `docs/DGX_SPARK_SETUP.md`

---

## Daily workflow

1) Talk to the PM agent (OpenClaw).
2) PM agent produces:
   - a plan (bulleted)
   - task tickets (numbered)
   - a “Coding Task Packet” (structured)
3) PM asks: “Approve delegating Ticket #N to coding agent?”
4) On approval, PM runs `scripts/run_claude_task.sh` which launches Claude Code with:
   - task packet
   - explicit instruction to **create subagents**
5) Claude Code edits files + runs tests, then reports results back.

---

## References (upstream docs used)
- vLLM OpenAI-compatible server docs: https://docs.vllm.ai/en/stable/serving/openai_compatible_server/
- OpenClaw vLLM provider docs: https://docs.openclaw.ai/providers/vllm
- OpenClaw exec approvals docs: https://beaverslab.mintlify.app/en/tools/exec-approvals
- Ollama Anthropic compatibility docs: https://docs.ollama.com/api/anthropic-compatibility
- Ollama Claude Code integration docs: https://docs.ollama.com/integrations/claude-code
- Ollama subagents + web search post: https://ollama.com/blog/web-search-subagents-claude-code


