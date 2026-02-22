#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"
LOCK_FILE="${LOCK_FILE:-$ROOT_DIR/config/base_model.lock.json}"

DEFAULT_VLLM_IMAGE="nvcr.io/nvidia/vllm:26.01-py3"
LEGACY_VLLM_IMAGE="vllm/vllm-openai:latest"
DEFAULT_VLLM_CONTAINER_NAME="vllm-nemotron"
LEGACY_VLLM_CONTAINER_NAME="vllm-pm"
DEFAULT_VLLM_MODEL="nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16"
LEGACY_VLLM_MODEL="nvidia/nemotron-3-nano-30b-a3b"
DEFAULT_VLLM_SERVED_MODEL_NAME="pm"
DEFAULT_VLLM_PORT="8000"
DEFAULT_VLLM_MAX_MODEL_LEN="32768"
DEFAULT_VLLM_ALLOW_LONG_MAX_MODEL_LEN="0"
DEFAULT_VLLM_TRUST_REMOTE_CODE="1"
DEFAULT_VLLM_ENABLE_PREFIX_CACHING="0"
DEFAULT_STARTUP_TIMEOUT_SEC="3600"
DEFAULT_STARTUP_POLL_SEC="10"
DEFAULT_HF_CACHE_DIR="${HOME}/.cache/huggingface"

LOCK_MODEL_REPO=""
LOCK_MODEL_REVISION=""

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command not found: $1"
    exit 1
  fi
}

print_vllm_logs_and_hints() {
  local container_name="$1"
  local logs
  logs="$(docker logs --tail 200 "${container_name}" 2>&1 || true)"
  echo "${logs}"
  if grep -q "Value 'sm_121a' is not defined for option 'gpu-name'" <<<"${logs}"; then
    echo "Hint: detected PTXAS/Triton mismatch for DGX Spark ('sm_121a')."
    echo "Use NVIDIA's Spark-compatible vLLM image with patched Triton/LLVM:"
    echo "  VLLM_IMAGE=${DEFAULT_VLLM_IMAGE}"
  fi
  if grep -Fq "/workspace/${VLLM_MODEL}: No such file or directory" <<<"${logs}"; then
    echo "Hint: this vLLM image expects an explicit launch command."
    echo "Use: vllm serve <model> ... (the setup script now does this automatically for nvcr.io/nvidia/vllm images)."
  fi
}

load_env_file() {
  if [[ -f "${ENV_FILE}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
  fi
}

load_lock_file() {
  if [[ ! -f "${LOCK_FILE}" ]]; then
    return
  fi
  require_cmd python3
  LOCK_MODEL_REPO="$(
    python3 - <<'PY' "${LOCK_FILE}"
import json
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
print(data.get("model_repo", ""))
PY
  )"
  LOCK_MODEL_REVISION="$(
    python3 - <<'PY' "${LOCK_FILE}"
import json
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
print(data.get("model_revision", ""))
PY
  )"
}

require_cmd docker
require_cmd curl
docker info >/dev/null 2>&1 || {
  echo "Error: docker daemon is not running or not accessible."
  exit 1
}

load_env_file
load_lock_file

if [[ -n "${LOCK_MODEL_REPO}" && -z "${VLLM_MODEL:-}" ]]; then
  VLLM_MODEL="${LOCK_MODEL_REPO}"
fi
if [[ -n "${LOCK_MODEL_REVISION}" && -z "${VLLM_MODEL_REVISION:-}" ]]; then
  VLLM_MODEL_REVISION="${LOCK_MODEL_REVISION}"
fi

VLLM_IMAGE="${VLLM_IMAGE:-${DEFAULT_VLLM_IMAGE}}"
VLLM_CONTAINER_NAME="${VLLM_CONTAINER_NAME:-${DEFAULT_VLLM_CONTAINER_NAME}}"
VLLM_MODEL="${VLLM_MODEL:-${DEFAULT_VLLM_MODEL}}"
VLLM_SERVED_MODEL_NAME="${VLLM_SERVED_MODEL_NAME:-${DEFAULT_VLLM_SERVED_MODEL_NAME}}"
VLLM_PORT="${VLLM_PORT:-${DEFAULT_VLLM_PORT}}"
VLLM_MAX_MODEL_LEN="${VLLM_MAX_MODEL_LEN:-${DEFAULT_VLLM_MAX_MODEL_LEN}}"
VLLM_ALLOW_LONG_MAX_MODEL_LEN="${VLLM_ALLOW_LONG_MAX_MODEL_LEN:-${DEFAULT_VLLM_ALLOW_LONG_MAX_MODEL_LEN}}"
VLLM_TRUST_REMOTE_CODE="${VLLM_TRUST_REMOTE_CODE:-${DEFAULT_VLLM_TRUST_REMOTE_CODE}}"
VLLM_ENABLE_PREFIX_CACHING="${VLLM_ENABLE_PREFIX_CACHING:-${DEFAULT_VLLM_ENABLE_PREFIX_CACHING}}"
STARTUP_TIMEOUT_SEC="${STARTUP_TIMEOUT_SEC:-${DEFAULT_STARTUP_TIMEOUT_SEC}}"
STARTUP_POLL_SEC="${STARTUP_POLL_SEC:-${DEFAULT_STARTUP_POLL_SEC}}"
HF_CACHE_DIR="${HF_CACHE_DIR:-${DEFAULT_HF_CACHE_DIR}}"

if [[ "${VLLM_IMAGE}" == "${LEGACY_VLLM_IMAGE}" ]]; then
  echo "Notice: remapping legacy image '${LEGACY_VLLM_IMAGE}' to '${DEFAULT_VLLM_IMAGE}' for DGX Spark compatibility."
  VLLM_IMAGE="${DEFAULT_VLLM_IMAGE}"
fi

USE_EXPLICIT_VLLM_SERVE=0
if [[ "${VLLM_IMAGE}" == nvcr.io/nvidia/vllm* ]]; then
  USE_EXPLICIT_VLLM_SERVE=1
fi

if [[ "${VLLM_MODEL}" == "${LEGACY_VLLM_MODEL}" ]]; then
  echo "Notice: remapping legacy model id '${LEGACY_VLLM_MODEL}' to '${DEFAULT_VLLM_MODEL}'."
  VLLM_MODEL="${DEFAULT_VLLM_MODEL}"
fi

if [[ -z "${HUGGING_FACE_HUB_TOKEN:-}" && -z "${HF_TOKEN:-}" ]]; then
  echo "Error: HF_TOKEN (or HUGGING_FACE_HUB_TOKEN) is not set."
  echo "Set it in ${ENV_FILE} or export it in your shell, then rerun."
  exit 1
fi

export HUGGING_FACE_HUB_TOKEN="${HUGGING_FACE_HUB_TOKEN:-${HF_TOKEN:-}}"

# vLLM requires this for model lengths that exceed the model config max.
if [[ "${VLLM_MAX_MODEL_LEN}" == "1M" ]]; then
  VLLM_ALLOW_LONG_MAX_MODEL_LEN=1
fi
if [[ "${VLLM_MAX_MODEL_LEN}" =~ ^[0-9]+$ ]] && (( VLLM_MAX_MODEL_LEN > 262144 )); then
  VLLM_ALLOW_LONG_MAX_MODEL_LEN=1
fi

mkdir -p "${HF_CACHE_DIR}"

echo "[1/5] Pulling image: ${VLLM_IMAGE}"
docker pull "${VLLM_IMAGE}"

if docker ps -a --format '{{.Names}}' | grep -qx "${VLLM_CONTAINER_NAME}"; then
  echo "[2/5] Removing existing container: ${VLLM_CONTAINER_NAME}"
  docker rm -f "${VLLM_CONTAINER_NAME}" >/dev/null
fi
if [[ "${VLLM_CONTAINER_NAME}" != "${LEGACY_VLLM_CONTAINER_NAME}" ]] && docker ps -a --format '{{.Names}}' | grep -qx "${LEGACY_VLLM_CONTAINER_NAME}"; then
  echo "[2/5] Removing legacy container: ${LEGACY_VLLM_CONTAINER_NAME}"
  docker rm -f "${LEGACY_VLLM_CONTAINER_NAME}" >/dev/null
fi

GPU_ARGS=(--gpus all)
if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"'; then
  GPU_ARGS=(--runtime nvidia --gpus all)
else
  echo "[2.5/5] Docker runtime 'nvidia' not detected; trying with --gpus all only."
fi

VLLM_ARGS=(
  "${VLLM_MODEL}"
  --host 0.0.0.0
  --port "${VLLM_PORT}"
  --served-model-name "${VLLM_SERVED_MODEL_NAME}"
  --dtype bfloat16
  --max-model-len "${VLLM_MAX_MODEL_LEN}"
)
case "${VLLM_ENABLE_PREFIX_CACHING}" in
  1|true|TRUE|yes|YES)
    VLLM_ARGS+=(--enable-prefix-caching)
    ;;
esac
case "${VLLM_TRUST_REMOTE_CODE}" in
  1|true|TRUE|yes|YES)
    VLLM_ARGS+=(--trust-remote-code)
    ;;
esac
if [[ -n "${VLLM_MODEL_REVISION:-}" ]]; then
  VLLM_ARGS+=(--revision "${VLLM_MODEL_REVISION}")
fi
if [[ -n "${VLLM_EXTRA_ARGS:-}" ]]; then
  # Intended for advanced users who need to pass additional vLLM CLI flags.
  read -r -a EXTRA_ARGS_ARR <<<"${VLLM_EXTRA_ARGS}"
  VLLM_ARGS+=("${EXTRA_ARGS_ARR[@]}")
fi

VLLM_CMD=("${VLLM_ARGS[@]}")
if [[ "${USE_EXPLICIT_VLLM_SERVE}" -eq 1 ]]; then
  VLLM_CMD=(vllm serve "${VLLM_ARGS[@]}")
fi

RUN_ARGS=(
  docker run -d
  --name "${VLLM_CONTAINER_NAME}"
  "${GPU_ARGS[@]}"
  --ipc=host
  -p "${VLLM_PORT}:8000"
  -v "${HF_CACHE_DIR}:/root/.cache/huggingface"
  -e HUGGING_FACE_HUB_TOKEN="${HUGGING_FACE_HUB_TOKEN}"
  -e VLLM_ALLOW_LONG_MAX_MODEL_LEN="${VLLM_ALLOW_LONG_MAX_MODEL_LEN}"
  "${VLLM_IMAGE}"
  "${VLLM_CMD[@]}"
)

echo "[3/5] Starting vLLM container: ${VLLM_CONTAINER_NAME}"
echo "      model=${VLLM_MODEL}"
echo "      model_revision=${VLLM_MODEL_REVISION:-<unset>}"
echo "      served_model_name=${VLLM_SERVED_MODEL_NAME}"
echo "      max_model_len=${VLLM_MAX_MODEL_LEN}"
echo "      allow_long_max_model_len=${VLLM_ALLOW_LONG_MAX_MODEL_LEN}"
echo "      trust_remote_code=${VLLM_TRUST_REMOTE_CODE}"
echo "      enable_prefix_caching=${VLLM_ENABLE_PREFIX_CACHING}"
echo "      port=${VLLM_PORT}"
echo "      cache_dir=${HF_CACHE_DIR}"
echo "      startup_timeout_sec=${STARTUP_TIMEOUT_SEC}"
if [[ "${USE_EXPLICIT_VLLM_SERVE}" -eq 1 ]]; then
  echo "      launch_cmd=vllm serve"
fi

set +e
RUN_OUTPUT="$("${RUN_ARGS[@]}" 2>&1)"
RUN_STATUS=$?
set -e

if [[ "${RUN_STATUS}" -ne 0 ]]; then
  echo "Error: failed to start vLLM container."
  echo "${RUN_OUTPUT}"
  if grep -q "unauthorized: authentication required" <<<"${RUN_OUTPUT}"; then
    echo "Hint: login to NGC if needed, then retry:"
    echo "  docker login nvcr.io"
    echo "  username: \$oauthtoken"
    echo "  password: <YOUR_NGC_API_KEY>"
  fi
  if grep -qi "unknown or invalid runtime name: nvidia" <<<"${RUN_OUTPUT}"; then
    echo "Hint: Docker does not know the 'nvidia' runtime. Install/configure NVIDIA Container Toolkit or rerun with only --gpus all."
  fi
  if grep -qi "could not select device driver" <<<"${RUN_OUTPUT}"; then
    echo "Hint: GPU driver/toolkit integration for Docker is missing."
    echo "Install NVIDIA Container Toolkit, restart Docker, then test:"
    echo "  docker run --rm --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi"
  fi
  exit 1
fi

echo "[4/5] Waiting for vLLM readiness on http://127.0.0.1:${VLLM_PORT}/v1/models"
READY=0
if ! [[ "${STARTUP_TIMEOUT_SEC}" =~ ^[0-9]+$ ]] || ! [[ "${STARTUP_POLL_SEC}" =~ ^[0-9]+$ ]] || [[ "${STARTUP_POLL_SEC}" -le 0 ]]; then
  echo "Error: STARTUP_TIMEOUT_SEC and STARTUP_POLL_SEC must be positive integers."
  exit 1
fi
MAX_POLLS=$(( (STARTUP_TIMEOUT_SEC + STARTUP_POLL_SEC - 1) / STARTUP_POLL_SEC ))
for _ in $(seq 1 "${MAX_POLLS}"); do
  if ! docker ps --format '{{.Names}}' | grep -qx "${VLLM_CONTAINER_NAME}"; then
    echo "Error: container '${VLLM_CONTAINER_NAME}' exited before readiness."
    echo "Recent logs:"
    print_vllm_logs_and_hints "${VLLM_CONTAINER_NAME}"
    exit 1
  fi
  if curl -fsS "http://127.0.0.1:${VLLM_PORT}/v1/models" >/tmp/vllm_models.json 2>/dev/null; then
    READY=1
    break
  fi
  sleep "${STARTUP_POLL_SEC}"
done

if [[ "${READY}" -ne 1 ]]; then
  echo "Error: vLLM did not become ready in time."
  echo "Recent logs:"
  print_vllm_logs_and_hints "${VLLM_CONTAINER_NAME}"
  exit 1
fi

echo "[5/5] vLLM is up."
if grep -q "\"${VLLM_SERVED_MODEL_NAME}\"" /tmp/vllm_models.json; then
  echo "Model '${VLLM_SERVED_MODEL_NAME}' is reported by /v1/models."
else
  echo "Warning: /v1/models is reachable but '${VLLM_SERVED_MODEL_NAME}' was not found yet."
  echo "Response:"
  cat /tmp/vllm_models.json
fi

echo "Done. PM endpoint: http://127.0.0.1:${VLLM_PORT}/v1"
