# DGX_SPARK_SETUP.md — One Spark Setup (OpenClaw PM + Claude Code Coding)

This guide sets up a **local, two-stack agent system** on **one DGX Spark**:

- **PM brain (planner/orchestrator):** OpenClaw (installed + configured via `ollama launch openclaw`)
  - You can run the PM model via **Ollama local/cloud models** (recommended), or
  - **Optionally** host **Nemotron3-Nano** locally via **vLLM or NIM** (mutually exclusive).
- **Coding agent (repo editor/executor):** **Claude Code** backed by **Ollama** using `qwen3-coder`
- **Delegation safety:** PM must ask for **your approval** before assigning work to the coding agent
- **Subagents:** coding agent is instructed to **spawn subagents** for parallel repo exploration when needed

---

## Table of contents

1. [0) Assumptions](#0-assumptions)
2. [1) Quick path (recommended): run repo setup scripts](#1-quick-path-recommended-run-repo-setup-scripts)
3. [2) Start Nemotron3-Nano model server for PM agent (optional; choose one, mutually exclusive)](#2-start-nemotron3-nano-model-server-for-pm-agent-optional-choose-one-mutually-exclusive)
   - [2A) Start vLLM (PM brain) - it takes ~82 GB VRAM](#2a-start-vllm-pm-brain---it-takes-82-gb-vram)
   - [2B) Start NIM (PM brain alternative on DGX Spark)](#2b-start-nim-pm-brain-alternative-on-dgx-spark)
   - [2C) Profile comparison table (NIM + Nemotron3-Nano on DGX Spark)](#2c-profile-comparison-table-nim--nemotron3-nano-on-dgx-spark)
4. [3) Start Ollama (coding agent backend) — background service](#3-start-ollama-coding-agent-backend--background-service)
5. [4) Install Claude Code and connect it to Ollama](#4-install-claude-code-and-connect-it-to-ollama)
6. [5) Install + launch OpenClaw via Ollama 0.17](#5-install--launch-openclaw-via-ollama-017)
7. [6) Add approval-gated delegation (Option B)](#6-add-approval-gated-delegation-option-b)
8. [7) Ensure PM reliably triggers subagents in the coding agent](#7-ensure-pm-reliably-triggers-subagents-in-the-coding-agent)
9. [8) End-to-end sanity test](#8-end-to-end-sanity-test)
10. [9) Troubleshooting](#9-troubleshooting)

---

## 0) Assumptions

- You’re on the DGX Spark host (Linux) with a working NVIDIA stack (`nvidia-smi` works).
- You have `sudo` access.
- You have Docker available with GPU access (only needed if you run the optional Nemotron vLLM/NIM PM backend).
- Default endpoints:
  - Optional PM model server (vLLM or NIM): `http://127.0.0.1:8000/v1`
  - Ollama: `http://127.0.0.1:11434`

> Recommended: run Ollama in **background** (systemd) so it survives SSH disconnects and reboots.

---

## 1) Quick path (recommended): run repo setup scripts

Pick one PM backend:

- **Recommended for most users:** use OpenClaw + **Ollama cloud/local models** (skip Section 2 entirely)
- **Optional / fully-local PM:** run **Nemotron3-Nano** via **vLLM or NIM** (Section 2)

From repo root:

```bash
cd /home/ryan/workspace/openclaw-personal-assistant
chmod +x scripts/setup_vllm_nemotron.sh scripts/setup_nim_nemotron.sh scripts/setup_ollama_claude.sh

# (A) Start Ollama as a background service + pull qwen3-coder + generate Claude env helper
./scripts/setup_ollama_claude.sh

# (Optional) If you want Nemotron PM locally (choose ONE):
# ./scripts/setup_vllm_nemotron.sh
# ./scripts/setup_nim_nemotron.sh

# Launch OpenClaw via Ollama (Ollama >= 0.17)
ollama launch openclaw
```

What the repo scripts do:

- `scripts/setup_vllm_nemotron.sh`
  - Loads `HF_TOKEN` from `.env` (or uses `HUGGING_FACE_HUB_TOKEN` if already exported)
  - Pulls `nvcr.io/nvidia/vllm:26.01-py3`
  - Starts Docker container `vllm-nemotron` on `http://127.0.0.1:8000`
  - Waits for `/v1/models` readiness

- `scripts/setup_nim_nemotron.sh`
  - Loads `NIM_*` vars from `.env`
  - Pulls `NIM_IMAGE` and launches NIM with Spark-style cache/workspace mounts
  - Starts Docker container `nim-nemotron` on `http://127.0.0.1:8000` by default
  - Supports `--list-profiles` and waits for `/v1/models` readiness

- `scripts/setup_ollama_claude.sh`
  - Installs/updates Ollama if missing
  - Starts Ollama as a **systemd background service** (`systemctl enable --now ollama`)
  - Waits until `http://127.0.0.1:11434` is responding
  - Pulls `qwen3-coder`
  - Writes `scripts/claude_ollama_env.sh` (generated) for Claude Code env vars
  - Checks whether `claude` CLI is installed

---

## 2) Start Nemotron3-Nano model server for PM agent (optional; choose one, mutually exclusive)

If you plan to use OpenClaw’s PM brain via **Ollama cloud/local models**, you can skip this entire section.

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
docker rm -f nim-nemotron 2>/dev/null || true
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
NIM_CONTAINER_NAME="nim-nemotron"
NIM_PORT=8000

NIM_MODEL_NAME="nvidia/nemotron-3-nano"
NIM_MODEL_PROFILE=""   # leave empty to select later

NIM_CACHE_DIR="$HOME/.cache/nim"
NIM_WORKSPACE_DIR="$HOME/.local/share/nim/workspace"
NIM_SHM_SIZE="16GB"

NIM_STARTUP_TIMEOUT_SEC=1200
NIM_STARTUP_POLL_SEC=10

NIM_NGC_API_KEY=""     # required
```

List profiles for the selected image (optional):

```bash
./scripts/setup_nim_nemotron.sh --list-profiles
```

Start (or restart) NIM:

```bash
docker rm -f vllm-nemotron 2>/dev/null || true
docker rm -f nim-nemotron 2>/dev/null || true
./scripts/setup_nim_nemotron.sh
```

Verify endpoint:

```bash
curl -v --max-time 10 http://127.0.0.1:8000/v1/models
```

If startup fails, inspect logs:

```bash
docker logs --tail 200 nim-nemotron
```

### 2C) Profile comparison table (NIM + Nemotron3-Nano on DGX Spark)

The table below uses `TP=1 / PP=1` (single DGX Spark).
VRAM "idle" is weights-focused; VRAM "peak" is scenario-modeled for `max_model_len=262,144` and `max_num_seqs=1`.

vLLM/NIM “used VRAM” ≈ (GPU total memory × NIM_KVCACHE_PERCENT) + runtime overhead, because vLLM pre-allocates the GPU KV cache up to that percentage; it only starts if (weights + minimum KV needed for NIM_MAX_MODEL_LEN × NIM_MAX_NUM_SEQS) ≤ (GPU total × percent)

Assumptions I’m using (so the numbers are concrete)
- DGX Spark total GPU memory commonly shows up as ~119.68 GiB (often displayed confusingly as “119.68 GB”), which is ~128.5 GB in decimal units.
- Your fixed settings: NIM_KVCACHE_PERCENT=0.45, NIM_MAX_MODEL_LEN=262144, NIM_MAX_NUM_SEQS=1
- Overhead” (CUDA context / workspaces / fragmentation etc.) ~ +7.2 GB (calibrated from your observed ~65 GB at 0.45).
- Profile list + the BF16 observed load number + FP8/NVFP4 file-size proxies are from your repo’s table.

| Profile name | Precision | TP/PP | VRAM idle (GB) | VRAM peak (GB) | Latency (ms/token) | Throughput (tok/s) | Notes | Recommendation |
|---|---:|---:|---:|---:|---:|---:|---|---|
| vLLM BF16 profile (NIM) | BF16 | TP1/PP1 | ~112 GB | ~115 GB | - | 25–30 (anecdotal) | Highest accuracy; largest memory footprint | Use if you prioritize max accuracy |
| vLLM FP8 profile (NIM) | FP8 | TP1/PP1 | ~65 GB | ~67 GB | ~48.6 | ~154.4 | Best accuracy/VRAM balance on Spark; strong perf | **Recommended** PM brain profile |
| vLLM NVFP4 profile (NIM listing) | NVFP4 | TP1/PP1 | ~65 GB | ~67 GB | ~36.5 | ~167.6 | Often fastest, but may be less stable depending on backend/kernel support | Not recommended if you hit stability issues |

---

## 3) Start Ollama (coding agent backend) — background service

### 3.1 Install / upgrade Ollama (recommend Ollama ≥ 0.17)

Install or upgrade:

```bash
curl -fsSL https://ollama.com/install.sh | sh
```

Check version:

```bash
ollama -v
```

### 3.2 Enable Ollama as a systemd service

```bash
sudo systemctl enable --now ollama
sudo systemctl status ollama --no-pager
```

Verify it responds:

```bash
curl -fsS http://127.0.0.1:11434/api/tags | head
```

View logs:

```bash
journalctl -e -u ollama
```

> If `ollama.service` is “not found”, your `scripts/setup_ollama_claude.sh` can create it automatically (recommended), or follow the official “Adding Ollama as a startup service” steps.

---

## 4) Install Claude Code and connect it to Ollama

### 4.1 Install Claude Code (CLI)

If `claude` is not installed yet:

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

Verify:

```bash
claude --version
```

### 4.2 Pull the coding model

```bash
ollama pull qwen3-coder
ollama list
ollama ps
```

### 4.3 Point Claude Code at Ollama (Anthropic-compatible endpoint)

```bash
export ANTHROPIC_AUTH_TOKEN=ollama  # required but ignored by Ollama
export ANTHROPIC_API_KEY=""         # required but ignored by Ollama
export ANTHROPIC_BASE_URL=http://127.0.0.1:11434
```

Test:

```bash
claude --model qwen3-coder
```

### 4.4 Repo helper (optional)

This repo’s `./scripts/setup_ollama_claude.sh` generates a helper you can source:

```bash
source scripts/claude_ollama_env.sh
claude --model qwen3-coder
```

---

## 5) Install + launch OpenClaw via Ollama 0.17

Ollama 0.17+ can install/configure OpenClaw automatically:

```bash
ollama launch openclaw
```

On first run, Ollama will:
1) prompt to install OpenClaw via **npm** (if missing),
2) show a security notice,
3) let you pick a model (local or cloud),
4) install the OpenClaw gateway daemon,
5) start the gateway in the background and open the OpenClaw TUI.

### 5.1 Prerequisite: Node.js (OpenClaw requires Node ≥ 22)

Check:

```bash
node -v || true
npm -v || true
```

If Node is missing or < 22, install Node 22 LTS (NodeSource):

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
node -v
npm -v
```

### 5.2 Launch OpenClaw (recommended)

Interactive:

```bash
ollama launch openclaw
```

Configure without starting the TUI/gateway immediately:

```bash
ollama launch openclaw --config
```

### 5.3 Stop the OpenClaw gateway

```bash
openclaw gateway stop
```

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

- `bash scripts/run_claude_task.sh <packet>`
- or `scripts/run_claude_task.sh <packet>`

Everything else should be denied by policy.

---

## 7) Ensure PM reliably triggers subagents in the coding agent

Enforcement:

- PM must include a “Subagent instruction (MANDATORY)” section in every task packet
- Wrapper script appends the mandatory subagent instruction even if the packet forgets

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

1) Start services:
   - Ollama: `http://127.0.0.1:11434` (systemd)
   - OpenClaw: `ollama launch openclaw` (gateway runs in background)
   - Optional PM backend (vLLM or NIM): `http://127.0.0.1:8000/v1`

2) In OpenClaw, ask PM:
   - “Goal: add a /health endpoint, update docs, and add tests. Plan it and delegate implementation.”

3) PM produces:
   - plan + tickets
   - a `packet.md` file content (you save it under `tasks/T001.md` for example)
   - asks: “Approve delegating Ticket T001 to coding agent?”

4) Approve.

5) PM runs:
   - `scripts/run_claude_task.sh tasks/T001.md`

6) Claude Code:
   - spawns subagents (repo exploration + tests)
   - implements changes
   - runs tests
   - returns summary + file list + commands run + test results

---

## 9) Troubleshooting

### Ollama service issues
- Status:
  ```bash
  sudo systemctl status ollama --no-pager
  ```
- Logs:
  ```bash
  journalctl -u ollama --no-pager --follow --pager-end
  ```

### Claude Code can’t connect
- Confirm:
  ```bash
  echo "$ANTHROPIC_BASE_URL"
  ```
  should be `http://127.0.0.1:11434`
- Confirm Ollama is running:
  ```bash
  curl http://127.0.0.1:11434/api/tags
  ```

### OpenClaw won’t install
- Confirm Node ≥ 22:
  ```bash
  node -v
  ```
- Confirm npm exists:
  ```bash
  npm -v
  ```

### vLLM OOM (optional PM backend)
- Reduce `--max-model-len`
- Reduce concurrency (if you set it)
- Ensure no other large model is pinned in GPU memory

### NIM startup issues (optional PM backend)
- Verify auth key is set: `NIM_NGC_API_KEY` (or `NGC_API_KEY`)
- List profiles first:
  ```bash
  ./scripts/setup_nim_nemotron.sh --list-profiles
  ```
- Check container logs:
  ```bash
  docker logs --tail 200 nim-nemotron
  ```
- Ensure vLLM is stopped before launching NIM:
  ```bash
  docker rm -f vllm-nemotron
  ```
