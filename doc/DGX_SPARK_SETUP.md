# DGX_SPARK_SETUP.md — One Spark Setup (OpenClaw PM + Claude Code Coding)

This guide sets up a **local, two-stack agent system** on **one DGX Spark**:

- **PM brain (planner/orchestrator):** OpenClaw + (vLLM or NIM, choose one at a time) + Nemotron-family model
- **Coding agent (repo editor/executor):** Claude Code + Ollama + `qwen3-coder`
- **Delegation safety:** PM must ask for **your approval** before assigning work to the coding agent
- **Subagents:** coding agent is instructed to **spawn subagents** for parallel repo exploration when needed

---

## 0) Assumptions

- You’re on the DGX Spark host (Linux) with a working NVIDIA stack.
- You have Docker available with GPU access.
- You will run:
  - PM model server (vLLM or NIM, not both at once) on `http://127.0.0.1:8000`
  - Ollama on `http://127.0.0.1:11434`
- You want **local-only / no external API cost** by default.

> Tip: If you later add web search, prefer self-hosted search (e.g., SearXNG) to avoid API billing.

---

## 1) Quick path (recommended): run repo setup scripts

Pick one PM backend:

- **vLLM path:** set `HF_TOKEN` in `.env`
- **NIM path:** set `NIM_IMAGE` and `NIM_NGC_API_KEY` (or `NGC_API_KEY`) in `.env`
- Do **not** run both PM backends at the same time for Nemotron3-Nano in this setup.

From repo root:

```bash
cd /home/ryan/workspace/openclaw-personal-assistant
chmod +x scripts/setup_vllm_nemotron.sh scripts/setup_nim_nemotron.sh scripts/setup_ollama_claude.sh

# Option A (vLLM PM backend)
./scripts/setup_vllm_nemotron.sh

# Option B (NIM PM backend)
# ./scripts/setup_nim_nemotron.sh

./scripts/setup_ollama_claude.sh
source scripts/claude_ollama_env.sh
claude --model qwen3-coder
```

What each script does:

* `scripts/setup_vllm_nemotron.sh`
  * loads `HF_TOKEN` from `.env` (or uses `HUGGING_FACE_HUB_TOKEN` if already exported)
  * pulls `nvcr.io/nvidia/vllm:26.01-py3`
  * starts Docker container `vllm-nemotron` on `http://127.0.0.1:8000`
  * waits for `/v1/models` readiness
* `scripts/setup_nim_nemotron.sh`
  * loads `NIM_*` vars from `.env` (and accepts NVIDIA alias vars like `IMG_NAME`)
  * logs into `nvcr.io`, pulls `NIM_IMAGE`, and launches NIM with Spark-style cache/workspace mounts
  * starts Docker container `nim-llm-demo` on `http://127.0.0.1:8000` by default
  * supports `--list-profiles` and waits for `/v1/models` readiness
* `scripts/setup_ollama_claude.sh`
  * ensures Ollama is running on `http://127.0.0.1:11434`
  * pulls `qwen3-coder`
  * writes `scripts/claude_ollama_env.sh` for Claude Code env vars
  * checks if `claude` CLI is installed

If you prefer explicit/manual steps, use sections 2-4 below.

---

## 2) Start Nemotron3-Nano model server for PM agent (choose one, mutually exclusive)

### 2A) Start vLLM (PM brain) - it takes ~82 GB VRAM

Use the repo script (do not run manual `docker run` commands for vLLM in this setup).

Recommended `.env` values:

```bash
VLLM_IMAGE="nvcr.io/nvidia/vllm:26.01-py3"
VLLM_CONTAINER_NAME="vllm-nemotron"
VLLM_MODEL="nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16"
VLLM_MAX_MODEL_LEN=262144
VLLM_ALLOW_LONG_MAX_MODEL_LEN=0
VLLM_TRUST_REMOTE_CODE=1
VLLM_ENABLE_PREFIX_CACHING=1
STARTUP_TIMEOUT_SEC=600
STARTUP_POLL_SEC=10
```

Start (or restart) vLLM:

```bash
docker rm -f nim-llm-demo 2>/dev/null || true
docker rm -f vllm-nemotron 2>/dev/null || true
./scripts/setup_vllm_nemotron.sh
```

Verify endpoint:

```bash
curl -v --max-time 10 http://127.0.0.1:8000/v1/models
```

If startup fails, inspect logs:

```bash
docker logs --tail 200 vllm-nemotron
```

### 2B) Start NIM (PM brain alternative on DGX Spark)

Use the repo script to keep Spark-specific mounts and env handling consistent.

Recommended `.env` values:

```bash
NIM_IMAGE="nvcr.io/nim/nvidia/nemotron-3-nano:1.7.0-variant"
NIM_CONTAINER_NAME="nim-llm-demo"
NIM_PORT=8000
NIM_MODEL_NAME=""
NIM_MODEL_PROFILE=""
NIM_CACHE_DIR="$HOME/.cache/nim"
NIM_WORKSPACE_DIR="$HOME/.local/share/nim/workspace"
NIM_SHM_SIZE="16GB"
NIM_STARTUP_TIMEOUT_SEC=1200
NIM_STARTUP_POLL_SEC=10
NIM_NGC_API_KEY="<your_ngc_api_key>"
```

List profiles for the selected image (optional):

```bash
./scripts/setup_nim_nemotron.sh --list-profiles
```

Start (or restart) NIM:

```bash
docker rm -f vllm-nemotron 2>/dev/null || true
docker rm -f nim-llm-demo 2>/dev/null || true
./scripts/setup_nim_nemotron.sh
```

Verify endpoint:

```bash
curl -v --max-time 10 http://127.0.0.1:8000/v1/models
```

If startup fails, inspect logs:

```bash
docker logs --tail 200 nim-llm-demo
```

---

## 3) Start Ollama (coding agent backend)

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

## 4) Install Claude Code and connect it to Ollama

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

## 5) Configure OpenClaw to use a local PM endpoint (vLLM or NIM)

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

* `baseUrl` must end with `/v1` because both vLLM and NIM expose OpenAI-compatible endpoints under that prefix.
* If you change `NIM_PORT` from `8000`, update `baseUrl` accordingly.
* `apiKey` can be any placeholder for local usage unless you configure auth.
* Keeping provider id `vllm` is fine even if the backend is NIM; it is just a local label in this config.

---

## 6) Add approval-gated delegation (Option B)

Goal: The PM agent can *only* trigger the coding agent through a **single wrapper script**, and OpenClaw will ask for approval before it runs.

### 6.1 Create the wrapper script

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

### 6.2 Configure OpenClaw exec approvals

In OpenClaw, enable exec approvals and allowlist only:

* `bash scripts/run_claude_task.sh <packet.md>`
* or `scripts/run_claude_task.sh <packet.md>`

Everything else should be denied by policy.

Expected behavior:

* PM proposes delegation
* OpenClaw asks you to approve the command
* Only then it executes the wrapper and launches Claude Code

---

## 7) Ensure PM reliably triggers subagents in the coding agent

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

## 8) End-to-end sanity test

1. Start services:

   * PM backend (vLLM or NIM): `http://127.0.0.1:8000`
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

## 9) Troubleshooting

### vLLM OOM

* Reduce `--max-model-len` from `32768` → `16384`
* Reduce concurrency (if you set it)
* Ensure no other large model is pinned in GPU memory

### NIM startup issues

* Verify auth key is set: `NIM_NGC_API_KEY` (or `NGC_API_KEY`)
* List profiles first: `./scripts/setup_nim_nemotron.sh --list-profiles`
* Check container logs: `docker logs --tail 200 nim-llm-demo`
* Ensure vLLM is stopped before launching NIM: `docker rm -f vllm-nemotron`

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
