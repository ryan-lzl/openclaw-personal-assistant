# DGX_SPARK_SETUP.md — One Spark Setup (OpenClaw PM + Claude Code Coding)

This guide sets up a **local, two-stack agent system** on **one DGX Spark**:

- **PM brain (planner/orchestrator):** OpenClaw + (vLLM or NIM, choose one at a time) + Nemotron-family model
- **Coding agent (repo editor/executor):** Claude Code + Ollama + `qwen3-coder`
- **Delegation safety:** PM must ask for **your approval** before assigning work to the coding agent
- **Subagents:** coding agent is instructed to **spawn subagents** for parallel repo exploration when needed

---

## Table of contents

1. [0) Assumptions](#0-assumptions)
2. [1) Quick path (recommended): run repo setup scripts](#1-quick-path-recommended-run-repo-setup-scripts)
3. [2) Start Nemotron3-Nano model server for PM agent (choose one, mutually exclusive)](#2-start-nemotron3-nano-model-server-for-pm-agent-choose-one-mutually-exclusive)
4. [2A) Start vLLM (PM brain) - it takes ~82 GB VRAM](#2a-start-vllm-pm-brain---it-takes-82-gb-vram)
5. [2B) Start NIM (PM brain alternative on DGX Spark)](#2b-start-nim-pm-brain-alternative-on-dgx-spark)
6. [2C) Profile comparison table (NIM + Nemotron3-Nano on DGX Spark)](#2c-profile-comparison-table-nim--nemotron3-nano-on-dgx-spark)
7. [3) Start Ollama (coding agent backend)](#3-start-ollama-coding-agent-backend)
8. [4) Install Claude Code and connect it to Ollama](#4-install-claude-code-and-connect-it-to-ollama)
9. [5) Configure OpenClaw to use a local PM endpoint (vLLM or NIM)](#5-configure-openclaw-to-use-a-local-pm-endpoint-vllm-or-nim)
10. [6) Add approval-gated delegation (Option B)](#6-add-approval-gated-delegation-option-b)
11. [7) Ensure PM reliably triggers subagents in the coding agent](#7-ensure-pm-reliably-triggers-subagents-in-the-coding-agent)
12. [8) End-to-end sanity test](#8-end-to-end-sanity-test)
13. [9) Troubleshooting](#9-troubleshooting)

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

### 2C) Profile comparison table (NIM + Nemotron3-Nano on DGX Spark)

The table below uses `TP=1 / PP=1` (single DGX Spark) and uses NVIDIA's cross-profile accuracy slice plus DGX Spark community performance where available.
VRAM "idle" is weights-focused (observed for BF16; file-size-based expectation for FP8/NVFP4).
VRAM "peak" is scenario-modeled for `max_model_len=262,144` and `max_num_seqs=8`, with KV cache dtype matched to common recommendations.

| Profile name | Precision | TP/PP | Accuracy metrics (dataset: score) | VRAM idle (GB) | VRAM peak (GB) | Latency (ms per token) | Throughput (tokens/s) | Notes on stability/compatibility | Recommendation |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| vLLM BF16 profile (NIM) | BF16 | TP1 / PP1 | MMLU-Pro: 78.3; AIME25 (no tools): 89.1; GPQA (no tools): 73.0; LiveCodeBench: 68.3; SciCode: 33.0; HLE (no tools): 10.2; TauBench V2 Airline/Retail/Telecom: 48.0/56.9/42.2 | 57.62 (observed load "mem usage") | ~71.7 (modeled, 256k x 8 seq) | - (no vLLM-bench result in collected sources) | 25-30 (anecdotal BF16 gen rate) | Highest accuracy; largest memory footprint; tuning `mamba-ssm-cache-dtype` impacts quality/perf. | Use if you prioritize maximum accuracy over VRAM/perf. |
| vLLM FP8 profile (NIM) | FP8 (selective BF16 kept in parts) | TP1 / PP1 | MMLU-Pro: 78.1; AIME25 (no tools): 87.7; GPQA (no tools): 72.5; LiveCodeBench: 67.6; SciCode: 31.9; HLE (no tools): 10.3; TauBench V2 Airline/Retail/Telecom: 44.8/55.6/40.8 | ~30.46 (profile file size proxy) | ~36.9 (modeled, 256k x 8 seq) | 48.61 (mean TPOT, benchmarked) | 154.40 (output tok/s, benchmarked) | Explicitly supported on DGX Spark in NIM profile list. Recommended to use FP8 KV cache and lower `gpu-memory-utilization` on DGX Spark for stability. | Recommended PM brain profile: best accuracy/VRAM balance with strong DGX Spark perf. |
| vLLM NVFP4 profile (NIM listing) | NVFP4 weights + FP8 KV (typical) | TP1 / PP1 | MMLU-Pro: 77.4; AIME25 (no tools): 86.7; GPQA (no tools): 71.9; LiveCodeBench: 65.4; SciCode: 30.7; HLE (no tools): 9.4; TauBench V2 Airline/Retail/Telecom: 41.5/54.1/41.2 | ~18.04 (profile file size proxy) | ~24.5 (modeled, 256k x 8 seq) | 36.53 (mean TPOT, benchmarked) | 167.61 (output tok/s, benchmarked) | Not listed as DGX Spark-supported in NIM profile table; multiple DGX Spark reports of backend/kernel friction and instability (misaligned address/Xid, MoE backend support errors). | Not recommended for "PM brain with NIM on DGX Spark" due to support + stability risk. |

#### Recommendation and OpenClaw PM brain integration notes

Recommended profile: FP8 vLLM profile under NIM (`TP1 / PP1`).

FP8 is the strongest choice for a DGX Spark "PM brain" under these constraints because:

- It is explicitly supported on DGX Spark in NVIDIA's NIM vLLM profile list.
- It is near-BF16 accuracy on NVIDIA's published evaluation slice (often within ~0.2-1.4 points depending on benchmark).
- It provides materially better VRAM headroom (file size ~30.46 GB) than BF16 (~58.84 GB), which matters on DGX Spark if you also want longer contexts, more concurrency, or additional services.
- DGX Spark community benchmarking shows strong serving throughput and token latency for FP8 under vLLM's benchmark harness.

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
