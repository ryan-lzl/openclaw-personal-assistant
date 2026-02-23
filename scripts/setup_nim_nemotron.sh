#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"
LOCK_FILE="${LOCK_FILE:-$ROOT_DIR/config/base_model.lock.json}"

DEFAULT_NIM_CONTAINER_NAME="nim-nemotron"
DEFAULT_NIM_PORT="8000"
DEFAULT_NIM_MODEL_NAME="nvidia/nemotron-3-nano"
DEFAULT_NIM_CACHE_DIR="${HOME}/.cache/nim"
DEFAULT_NIM_CACHE_MOUNT="/opt/nim/.cache"
DEFAULT_NIM_WORKSPACE_DIR="${HOME}/.local/share/nim/workspace"
DEFAULT_NIM_WORKSPACE_MOUNT="/opt/nim/workspace"
DEFAULT_NIM_SHM_SIZE="16GB"
DEFAULT_NIM_STARTUP_TIMEOUT_SEC="1200"
DEFAULT_NIM_STARTUP_POLL_SEC="10"

LOCK_MODEL_REPO=""
LOCK_MODEL_REVISION=""

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command not found: $1"
    exit 1
  fi
}

print_nim_logs_and_hints() {
  local container_name="$1"
  local logs
  logs="$(docker logs --tail 200 "${container_name}" 2>&1 || true)"
  echo "${logs}"
  if grep -qi "unauthorized: authentication required" <<<"${logs}"; then
    echo "Hint: registry auth failed. Recheck NIM_NGC_API_KEY/NGC_API_KEY and docker login nvcr.io."
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

NIM_IMAGE="${NIM_IMAGE:-${IMG_NAME:-}}"
NIM_CONTAINER_NAME="${NIM_CONTAINER_NAME:-${CONTAINER_NAME:-${DEFAULT_NIM_CONTAINER_NAME}}}"
NIM_PORT="${NIM_PORT:-${DEFAULT_NIM_PORT}}"
NIM_CACHE_DIR="${NIM_CACHE_DIR:-${LOCAL_NIM_CACHE:-${DEFAULT_NIM_CACHE_DIR}}}"
NIM_CACHE_MOUNT="${NIM_CACHE_MOUNT:-${DEFAULT_NIM_CACHE_MOUNT}}"
NIM_WORKSPACE_DIR="${NIM_WORKSPACE_DIR:-${LOCAL_NIM_WORKSPACE:-${DEFAULT_NIM_WORKSPACE_DIR}}}"
NIM_WORKSPACE_MOUNT="${NIM_WORKSPACE_MOUNT:-${DEFAULT_NIM_WORKSPACE_MOUNT}}"
NIM_SHM_SIZE="${NIM_SHM_SIZE:-${DEFAULT_NIM_SHM_SIZE}}"
NIM_MODEL_NAME="${NIM_MODEL_NAME:-${DEFAULT_NIM_MODEL_NAME}}"
NIM_MODEL_PROFILE="${NIM_MODEL_PROFILE:-}"
NIM_STARTUP_TIMEOUT_SEC="${NIM_STARTUP_TIMEOUT_SEC:-${DEFAULT_NIM_STARTUP_TIMEOUT_SEC}}"
NIM_STARTUP_POLL_SEC="${NIM_STARTUP_POLL_SEC:-${DEFAULT_NIM_STARTUP_POLL_SEC}}"
NIM_NGC_API_KEY="${NIM_NGC_API_KEY:-${NGC_API_KEY:-}}"

if [[ -z "${NIM_IMAGE}" ]]; then
  echo "Error: NIM_IMAGE is not set."
  echo "Set it in ${ENV_FILE} or export it in your shell, then rerun."
  exit 1
fi

if [[ -z "${NIM_NGC_API_KEY}" ]]; then
  echo "Error: NIM_NGC_API_KEY (or NGC_API_KEY) is not set."
  echo "Set it in ${ENV_FILE} or export it in your shell, then rerun."
  exit 1
fi

if ! [[ "${NIM_NGC_API_KEY}" =~ ^[A-Za-z0-9]{86}==$ ]]; then
  echo "Warning: NGC API key does not match the expected DGX Spark format (86 chars plus '==')."
fi

if ! [[ "${NIM_STARTUP_TIMEOUT_SEC}" =~ ^[0-9]+$ ]] || ! [[ "${NIM_STARTUP_POLL_SEC}" =~ ^[0-9]+$ ]] || [[ "${NIM_STARTUP_POLL_SEC}" -le 0 ]]; then
  echo "Error: NIM_STARTUP_TIMEOUT_SEC and NIM_STARTUP_POLL_SEC must be positive integers."
  exit 1
fi

mkdir -p "${NIM_CACHE_DIR}"
mkdir -p "${NIM_WORKSPACE_DIR}"
# NVIDIA Spark instructions use world-writable cache/workspace paths for container writes.
chmod -R a+w "${NIM_CACHE_DIR}" "${NIM_WORKSPACE_DIR}" 2>/dev/null || true

echo "[1/6] Logging in to nvcr.io"
printf '%s' "${NIM_NGC_API_KEY}" | docker login nvcr.io -u '$oauthtoken' --password-stdin >/dev/null 2>&1 || {
  echo "Error: docker login to nvcr.io failed. Check NIM_NGC_API_KEY/NGC_API_KEY."
  exit 1
}

echo "[2/6] Pulling image: ${NIM_IMAGE}"
docker pull "${NIM_IMAGE}"

if docker ps -a --format '{{.Names}}' | grep -qx "${NIM_CONTAINER_NAME}"; then
  echo "[3/6] Removing existing container: ${NIM_CONTAINER_NAME}"
  docker rm -f "${NIM_CONTAINER_NAME}" >/dev/null
fi

GPU_ARGS=(--gpus all)
if docker info --format '{{json .Runtimes}}' 2>/dev/null | grep -q '"nvidia"'; then
  GPU_ARGS=(--runtime nvidia --gpus all)
else
  echo "[3.5/6] Docker runtime 'nvidia' not detected; trying with --gpus all only."
fi

if [[ "${1:-}" == "--list-profiles" ]]; then
  echo "[4/6] Listing model profiles for ${NIM_IMAGE}"
  LIST_PROFILE_ARGS=(docker run --rm "${GPU_ARGS[@]}" -e NGC_API_KEY="${NIM_NGC_API_KEY}")
  if [[ -n "${NIM_MODEL_NAME}" ]]; then
    LIST_PROFILE_ARGS+=(-e NIM_MODEL_NAME="${NIM_MODEL_NAME}")
  fi
  exec "${LIST_PROFILE_ARGS[@]}" "${NIM_IMAGE}" list-model-profiles
fi

RUN_ARGS=(
  docker run -d
  --name "${NIM_CONTAINER_NAME}"
  "${GPU_ARGS[@]}"
  --shm-size="${NIM_SHM_SIZE}"
  -p "${NIM_PORT}:8000"
  -v "${NIM_CACHE_DIR}:${NIM_CACHE_MOUNT}"
  -v "${NIM_WORKSPACE_DIR}:${NIM_WORKSPACE_MOUNT}"
  -e NGC_API_KEY="${NIM_NGC_API_KEY}"
)

if [[ -n "${NIM_MODEL_NAME}" ]]; then
  RUN_ARGS+=(-e NIM_MODEL_NAME="${NIM_MODEL_NAME}")
fi
if [[ -n "${NIM_MODEL_PROFILE}" ]]; then
  RUN_ARGS+=(-e NIM_MODEL_PROFILE="${NIM_MODEL_PROFILE}")
fi
if [[ -n "${NIM_EXTRA_ENV:-}" ]]; then
  # Intended for advanced users who need additional -e KEY=VALUE flags.
  read -r -a EXTRA_ENV_ARR <<<"${NIM_EXTRA_ENV}"
  RUN_ARGS+=("${EXTRA_ENV_ARR[@]}")
fi
if [[ -n "${NIM_EXTRA_ARGS:-}" ]]; then
  # Intended for advanced users who need additional docker run flags.
  read -r -a EXTRA_ARGS_ARR <<<"${NIM_EXTRA_ARGS}"
  RUN_ARGS+=("${EXTRA_ARGS_ARR[@]}")
fi

RUN_ARGS+=("${NIM_IMAGE}")

echo "[4/6] Starting NIM container: ${NIM_CONTAINER_NAME}"
echo "      nim_image=${NIM_IMAGE}"
echo "      model_repo=${LOCK_MODEL_REPO:-<unset>}"
echo "      model_revision=${LOCK_MODEL_REVISION:-<unset>}"
echo "      nim_model_name=${NIM_MODEL_NAME:-<unset>}"
echo "      nim_model_profile=${NIM_MODEL_PROFILE:-<unset>}"
echo "      port=${NIM_PORT}"
echo "      cache_dir=${NIM_CACHE_DIR}"
echo "      cache_mount=${NIM_CACHE_MOUNT}"
echo "      workspace_dir=${NIM_WORKSPACE_DIR}"
echo "      workspace_mount=${NIM_WORKSPACE_MOUNT}"
echo "      shm_size=${NIM_SHM_SIZE}"
echo "      startup_timeout_sec=${NIM_STARTUP_TIMEOUT_SEC}"

set +e
RUN_OUTPUT="$("${RUN_ARGS[@]}" 2>&1)"
RUN_STATUS=$?
set -e

if [[ "${RUN_STATUS}" -ne 0 ]]; then
  echo "Error: failed to start NIM container."
  echo "${RUN_OUTPUT}"
  if grep -qi "unknown or invalid runtime name: nvidia" <<<"${RUN_OUTPUT}"; then
    echo "Hint: Docker does not know the 'nvidia' runtime. Install/configure NVIDIA Container Toolkit."
  fi
  if grep -qi "could not select device driver" <<<"${RUN_OUTPUT}"; then
    echo "Hint: GPU driver/toolkit integration for Docker is missing."
    echo "Test with: docker run --rm --gpus all nvidia/cuda:13.0.1-devel-ubuntu24.04 nvidia-smi"
  fi
  exit 1
fi

echo "[5/6] Waiting for readiness on http://127.0.0.1:${NIM_PORT}/v1/models"
READY=0
MAX_POLLS=$(( (NIM_STARTUP_TIMEOUT_SEC + NIM_STARTUP_POLL_SEC - 1) / NIM_STARTUP_POLL_SEC ))
for _ in $(seq 1 "${MAX_POLLS}"); do
  if ! docker ps --format '{{.Names}}' | grep -qx "${NIM_CONTAINER_NAME}"; then
    echo "Error: container '${NIM_CONTAINER_NAME}' exited before readiness."
    echo "Recent logs:"
    print_nim_logs_and_hints "${NIM_CONTAINER_NAME}"
    exit 1
  fi
  if curl -fsS "http://127.0.0.1:${NIM_PORT}/v1/models" >/tmp/nim_models.json 2>/dev/null; then
    READY=1
    break
  fi
  sleep "${NIM_STARTUP_POLL_SEC}"
done

if [[ "${READY}" -ne 1 ]]; then
  echo "Error: NIM did not become ready in time."
  echo "Recent logs:"
  print_nim_logs_and_hints "${NIM_CONTAINER_NAME}"
  exit 1
fi

echo "[6/6] NIM is up."
if [[ -n "${NIM_MODEL_NAME}" ]] && grep -q "\"${NIM_MODEL_NAME}\"" /tmp/nim_models.json; then
  echo "Model '${NIM_MODEL_NAME}' is reported by /v1/models."
fi
echo "Done. Model '${NIM_MODEL_NAME}' endpoint: http://127.0.0.1:${NIM_PORT}/v1"
