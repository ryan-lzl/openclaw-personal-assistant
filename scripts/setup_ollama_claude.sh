#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://127.0.0.1:11434}"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen3-coder}"
CLAUDE_ENV_FILE="${REPO_ROOT}/scripts/claude_ollama_env.sh"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command not found: $1"
    exit 1
  fi
}

ollama_ready() {
  curl -fsS "${OLLAMA_BASE_URL}/api/tags" >/dev/null 2>&1
}

require_cmd curl
require_cmd ollama

echo "[1/5] Ensuring Ollama is running at ${OLLAMA_BASE_URL}"
if ! ollama_ready; then
  echo "Ollama is not reachable. Starting 'ollama serve' in background..."
  nohup ollama serve >/tmp/ollama-serve.log 2>&1 &
fi

READY=0
for _ in $(seq 1 30); do
  if ollama_ready; then
    READY=1
    break
  fi
  sleep 2
done

if [[ "${READY}" -ne 1 ]]; then
  echo "Error: Ollama did not become ready."
  echo "Check log: /tmp/ollama-serve.log"
  exit 1
fi

echo "[2/5] Pulling coding model: ${OLLAMA_MODEL}"
ollama pull "${OLLAMA_MODEL}"

echo "[3/5] Writing Claude env helper: ${CLAUDE_ENV_FILE}"
cat > "${CLAUDE_ENV_FILE}" <<EOF
#!/usr/bin/env bash
export ANTHROPIC_AUTH_TOKEN=ollama
export ANTHROPIC_API_KEY=""
export ANTHROPIC_BASE_URL=${OLLAMA_BASE_URL}
EOF
chmod +x "${CLAUDE_ENV_FILE}"

echo "[4/5] Current Ollama models:"
ollama list || true

echo "[5/5] Claude Code check:"
if command -v claude >/dev/null 2>&1; then
  claude --version || true
  echo "Claude Code is installed."
  echo "Run: source scripts/claude_ollama_env.sh"
  echo "Then: claude --model ${OLLAMA_MODEL}"
else
  echo "Claude Code CLI is not installed yet."
  echo "Install Claude Code, then run:"
  echo "  source scripts/claude_ollama_env.sh"
  echo "  claude --model ${OLLAMA_MODEL}"
fi

echo "Done. Ollama endpoint: ${OLLAMA_BASE_URL}"
