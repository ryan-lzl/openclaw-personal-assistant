# OpenClaw Personal Assistant

## DGX Spark PM + Coding Agent Stack (OpenClaw + vLLM/NIM + Claude Code + Ollama)

A local, no-API-cost(ish) agent stack optimized for **repo-level issue fixing** and **PM-style planning**:

- **PM brain (planner/orchestrator):** OpenClaw → (vLLM or NIM) → `nemotron-3-nano`
- **Coding agent (repo editor/executor):** Claude Code → Ollama → `qwen3-coder`
- **Search:** optional (Brave API or self-hosted search). Coding subagents prioritize repo exploration and local execution.
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
└── scripts/
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
   - allow only your approved task delegation command(s)
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
docker rm -f nim-llm-demo vllm-nemotron 2>/dev/null || true
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
docker rm -f vllm-nemotron nim-llm-demo 2>/dev/null || true
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
docker logs --tail 200 nim-llm-demo
```

See full setup guide: `doc/DGX_SPARK_SETUP.md`

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
- NVIDIA NIM supported models docs: https://docs.nvidia.com/nim/large-language-models/latest/supported-models.html
- NVIDIA DGX Spark NIM overview: https://build.nvidia.com/spark/nim-llm/overview
- NVIDIA DGX Spark NIM instructions: https://build.nvidia.com/spark/nim-llm/instructions
- OpenClaw vLLM provider docs: https://docs.openclaw.ai/providers/vllm
- OpenClaw exec approvals docs: https://beaverslab.mintlify.app/en/tools/exec-approvals
- Ollama Anthropic compatibility docs: https://docs.ollama.com/api/anthropic-compatibility
- Ollama Claude Code integration docs: https://docs.ollama.com/integrations/claude-code
- Ollama subagents + web search post: https://ollama.com/blog/web-search-subagents-claude-code

