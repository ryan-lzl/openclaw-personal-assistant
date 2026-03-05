# OpenClaw Personal Assistant

## DGX Spark PM + Coding Agent Stack (OpenClaw + vLLM/NIM + Claude Code + Ollama)

A local, no-API-cost(ish) agent stack optimized for **repo-level issue fixing** and **PM-style planning**:

- **PM brain (planner/orchestrator):** OpenClaw → (vLLM or NIM) → `nemotron-3-nano`
- **Coding agent (repo editor/executor):** Claude Code → Ollama → `qwen3-coder`
- **Search:** optional. Default is local-only; when needed, coding tasks can enable web search via Ollama cloud models.
- **Backend policy:** run **one** PM backend at a time (vLLM or NIM), not both simultaneously.

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
```bash
.
├── README.md
├── doc/
│ ├── DGX_SPARK_SETUP.md
│ ├── IDENTITY.md
│ ├── PRD.md
│ └── SOUL.md
├── config/
├── .claude/
│ └── skills/
│   └── openclaw-delegate/
│     └── SKILL.md
├── tasks/
│ └── TEMPLATE_PACKET.md
└── scripts/
  ├── run_claude_task.sh
  ├── setup_vllm_nemotron.sh
  ├── setup_nim_nemotron.sh
  └── setup_ollama_claude.sh
```

---

## Quick start

1) Start **one** PM backend for Nemotron3-Nano:
   - `scripts/setup_vllm_nemotron.sh` (vLLM)
   - `scripts/setup_nim_nemotron.sh` (NIM)
2) Start Ollama backend for coding:
   - `scripts/setup_ollama_claude.sh`
3) Configure OpenClaw to:
   - use vLLM as primary model
   - point `baseUrl` to your PM endpoint (`http://127.0.0.1:8000/v1`)
   - allow only `scripts/run_claude_task.sh <packet.md>` as delegation command
   - keep project skill `.claude/skills/openclaw-delegate/SKILL.md` in repo
4) Use the **handoff protocol** to dispatch coding tasks (approval required).

---

## PM backend options (mutually exclusive)

### Option A: vLLM

Prerequisite in `.env`:

```bash
HF_TOKEN="<your_hf_token>"
```

Run:

```bash
docker rm -f nim-nemotron vllm-nemotron 2>/dev/null || true
./scripts/setup_vllm_nemotron.sh
```

### Option B: NIM

Prerequisites in `.env`:

```bash
NIM_IMAGE="nvcr.io/nim/nvidia/nemotron-3-nano:1.7.0-variant"
NIM_NGC_API_KEY="<your_ngc_api_key>"
```

Optional profile discovery:

```bash
./scripts/setup_nim_nemotron.sh --list-profiles
```

Run:

```bash
docker rm -f vllm-nemotron nim-nemotron 2>/dev/null || true
./scripts/setup_nim_nemotron.sh
```

---

## Verify PM endpoint

```bash
curl -v --max-time 10 http://127.0.0.1:8000/v1/models
```

If startup fails:

```bash
docker logs --tail 200 vllm-nemotron
docker logs --tail 200 nim-nemotron
```

See full setup guide: `doc/DGX_SPARK_SETUP.md`

---

## Daily workflow

1) Talk to the PM agent (OpenClaw).
2) PM agent produces:
   - a plan (bulleted)
   - task tickets (numbered)
   - a “Coding Task Packet” (structured, based on `tasks/TEMPLATE_PACKET.md`)
3) PM asks: “Approve delegating Ticket #N to coding agent?”
4) On approval, PM runs `scripts/run_claude_task.sh` which launches Claude Code with:
   - task packet
   - validated subagent range from packet (`Subagents Min` / `Subagents Max`)
   - web-search mode derived from packet (`Web Search: off|optional|required`) or env override
   - auto-switch to cloud model for `Web Search: required` (from `Web Search Model` or `WEB_SEARCH_CLOUD_MODEL`)
   - delegation through project skill `/openclaw-delegate <packet.md>`
5) Claude Code edits files + runs tests, then reports results back.

---

## Reliable subagents + web search

Use this checklist for consistent behavior:

1) Always dispatch through `scripts/run_claude_task.sh` (never direct `claude ...` from PM).
2) Keep OpenClaw exec allowlist narrow:
   - `scripts/run_claude_task.sh <packet.md>`
   - Do not use `bash scripts/run_claude_task.sh ...` (this should be blocked by allowlist policy).
3) Keep project skill in-repo and versioned:
   - `.claude/skills/openclaw-delegate/SKILL.md`
4) Create packets from `tasks/TEMPLATE_PACKET.md` and include:
   - `Web Search: off|optional|required`
   - optional `Web Search Model: <name>:cloud` (used when search is required)
   - `Subagents Min: 2..10`
   - `Subagents Max: 2..10` (must be >= min)
   - `Subagent instruction (MANDATORY)`
5) Choose model by task type:
   - local/offline coding: `CLAUDE_MODEL=qwen3-coder`
   - web-search-required tasks: wrapper auto-switches to `WEB_SEARCH_CLOUD_MODEL` (default `minimax-m2.5:cloud`) if needed
6) If you need hosted search subagents from Ollama, initialize Claude Code via:
   - `ollama launch claude --model minimax-m2.5:cloud --subagents search-web,search-github,search-docs`

---

## References (upstream docs used)
- vLLM OpenAI-compatible server docs: https://docs.vllm.ai/en/stable/serving/openai_compatible_server/
- NVIDIA NIM supported models docs: https://docs.nvidia.com/nim/large-language-models/latest/supported-models.html
- NVIDIA DGX Spark NIM overview: https://build.nvidia.com/spark/nim-llm/overview
- NVIDIA DGX Spark NIM instructions: https://build.nvidia.com/spark/nim-llm/instructions
- OpenClaw vLLM provider docs: https://docs.openclaw.ai/providers/vllm
- OpenClaw exec approvals docs: https://beaverslab.mintlify.app/en/tools/exec-approvals
- Ollama Anthropic compatibility docs: https://docs.ollama.com/api/anthropic-compatibility
- Ollama Claude Code integration docs: https://docs.ollama.com/integrations/claude-code
- Ollama subagents + web search post: https://ollama.com/blog/web-search-subagents-claude-code
- Claude Skills docs: https://code.claude.com/docs/en/skills
- Anthropic skills repository: https://github.com/anthropics/skills
