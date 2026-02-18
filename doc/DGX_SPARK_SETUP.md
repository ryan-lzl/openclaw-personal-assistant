# DGX_SPARK_SETUP.md — One Spark Setup (OpenClaw PM + Claude Code Coding)

This guide sets up a **local, two-stack agent system** on **one DGX Spark**:

- **PM brain (planner/orchestrator):** OpenClaw + vLLM + `nemotron-3-nano-30b-a3b`
- **Coding agent (repo editor/executor):** Claude Code + Ollama + `qwen3-coder`
- **Delegation safety:** PM must ask for **your approval** before assigning work to the coding agent
- **Subagents:** coding agent is instructed to **spawn subagents** for parallel repo exploration when needed

---

## 0) Assumptions

- You’re on the DGX Spark host (Linux) with a working NVIDIA stack.
- You have Docker available (recommended) or can run Python vLLM directly.
- You will run:
  - vLLM (PM) on `http://127.0.0.1:8000`
  - Ollama on `http://127.0.0.1:11434`
- You want **local-only / no external API cost** by default.

> Tip: If you later add web search, prefer self-hosted search (e.g., SearXNG) to avoid API billing.

---

## 1) Start vLLM (PM brain)

### Option A — Docker (recommended)

Pull the vLLM OpenAI-compatible server image:

```bash
docker pull vllm/vllm-openai:nightly
````

Set a Hugging Face token for downloading models (if needed):

```bash
export HF_TOKEN="hf_xxx_your_token"
mkdir -p ~/.cache/huggingface
```

Run the PM brain server:

```bash
docker run -d --name vllm-pm \
  --runtime nvidia --gpus all --ipc=host \
  -p 8000:8000 \
  -v ~/.cache/huggingface:/root/.cache/huggingface \
  -e HUGGING_FACE_HUB_TOKEN=$HF_TOKEN \
  vllm/vllm-openai:nightly \
    --model nvidia/nemotron-3-nano-30b-a3b \
    --served-model-name pm \
    --dtype bfloat16 \
    --max-model-len 32768 \
    --enable-prefix-caching
```

Quick check:

```bash
curl -s http://127.0.0.1:8000/v1/models
```

If you see `"pm"` in the model list, vLLM is up.

---

## 2) Start Ollama (coding agent backend)

Install Ollama (use Ollama’s official install method), then start it:

```bash
ollama serve
```

Pull the coding model:

```bash
ollama pull qwen3-coder
```

Verify the model is loaded/available:

```bash
ollama list
ollama ps
```

---

## 3) Install Claude Code and connect it to Ollama

Install Claude Code (follow Claude Code’s official install steps on your OS).

Set Claude Code to use Ollama’s **Anthropic-compatible** endpoint:

```bash
export ANTHROPIC_AUTH_TOKEN=ollama
export ANTHROPIC_API_KEY=""
export ANTHROPIC_BASE_URL=http://127.0.0.1:11434
```

Test launching Claude Code with the local model:

```bash
claude --model qwen3-coder
```

If it opens a session and responds, Claude Code ↔ Ollama works.

---

## 4) Configure OpenClaw to use vLLM as the PM model

Create `config/openclaw.json` (example):

```json
{
  "models": {
    "providers": {
      "vllm": {
        "api": "openai-completions",
        "baseUrl": "http://127.0.0.1:8000/v1",
        "apiKey": "vllm-local"
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "vllm/pm"
      }
    }
  }
}
```

Notes:

* `baseUrl` must end with `/v1` because vLLM exposes OpenAI-compatible endpoints under that prefix.
* `apiKey` can be any placeholder for local usage unless you configure auth.

---

## 5) Add approval-gated delegation (Option B)

Goal: The PM agent can *only* trigger the coding agent through a **single wrapper script**, and OpenClaw will ask for approval before it runs.

### 5.1 Create the wrapper script

Create `scripts/run_claude_task.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

PACKET_FILE="${1:-}"
if [[ -z "${PACKET_FILE}" || ! -f "${PACKET_FILE}" ]]; then
  echo "Usage: $0 <packet.md>"
  exit 1
fi

# Claude Code -> Ollama Anthropic compatibility
export ANTHROPIC_AUTH_TOKEN=ollama
export ANTHROPIC_API_KEY=""
export ANTHROPIC_BASE_URL=http://127.0.0.1:11434

MODEL="qwen3-coder"

# Force subagents by instruction.
PROMPT="$(cat "${PACKET_FILE}")

MANDATORY:
- Create subagents to parallelize repo exploration and test mapping before coding.
- Then implement the tasks and run tests.
- Return: summary, files changed, commands run, test results."

exec claude --model "${MODEL}" --prompt "${PROMPT}"
```

Make it executable:

```bash
chmod +x scripts/run_claude_task.sh
```

### 5.2 Configure OpenClaw exec approvals

In OpenClaw, enable exec approvals and allowlist only:

* `bash scripts/run_claude_task.sh <packet.md>`
* or `scripts/run_claude_task.sh <packet.md>`

Everything else should be denied by policy.

Expected behavior:

* PM proposes delegation
* OpenClaw asks you to approve the command
* Only then it executes the wrapper and launches Claude Code

---

## 6) Ensure PM reliably triggers subagents in the coding agent

Claude Code subagent behavior is tool-driven, but you can reliably nudge it by including the explicit phrase:

* “Create subagents …” / “Spawn subagents …”

Enforcement:

* PM must include a “Subagent instruction (MANDATORY)” section in every task packet
* Wrapper script appends a mandatory subagent instruction even if the packet forgets

Recommended packet template:

```md
## Subagent instruction (MANDATORY)
Create subagents to parallelize:
1) Map relevant entrypoints and code paths
2) Locate tests and how to run them
3) Catalog conventions/patterns used in this repo
```

---

## 7) End-to-end sanity test

1. Start services:

   * vLLM PM: `http://127.0.0.1:8000`
   * Ollama: `http://127.0.0.1:11434`

2. In OpenClaw, ask PM:

   * “Goal: add a /health endpoint, update docs, and add tests. Plan it and delegate implementation.”

3. PM produces:

   * plan + tickets
   * a `packet.md` file content (you save it under `tasks/T001.md` for example)
   * asks: “Approve delegating Ticket T001 to coding agent?”

4. Approve.

5. PM runs:

   * `scripts/run_claude_task.sh tasks/T001.md`

6. Claude Code:

   * spawns subagents (repo exploration + tests)
   * implements changes
   * runs tests
   * returns summary + file list + commands run + test results

Done.

---

## 8) Troubleshooting

### vLLM OOM

* Reduce `--max-model-len` from `32768` → `16384`
* Reduce concurrency (if you set it)
* Ensure no other large model is pinned in GPU memory

### Ollama slow / CPU offload

* Reduce context length
* Use smaller coding model if needed
* Confirm `ollama ps` shows it running on GPU

### Claude Code can’t connect

* Confirm:

  * `echo $ANTHROPIC_BASE_URL` is `http://127.0.0.1:11434`
  * Ollama is running: `curl http://127.0.0.1:11434/api/tags`

### PM didn’t spawn subagents

* Ensure the packet explicitly says: “Create subagents …”
* Wrapper script appends the mandatory instruction; confirm you’re using it to launch Claude Code

```
::contentReference[oaicite:0]{index=0}
```
