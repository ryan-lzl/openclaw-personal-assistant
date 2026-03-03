#!/usr/bin/env bash
set -euo pipefail

# setup_ollama_claude.sh
#
# Goal:
# - Ensure Ollama is installed
# - Ensure Ollama is running as a *background* systemd service
# - Pull required qwen3-coder source models
# - Create local aliases used by Claude
# - Generate scripts/claude_ollama_env.sh for Claude Code (Anthropic-compatible)
#
# This script is designed to match the "background method" described in DGX_SPARK_SETUP.md.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

O_HOST="${OLLAMA_HOST_ADDR:-127.0.0.1}"
O_PORT="${OLLAMA_PORT:-11434}"
O_URL="http://${O_HOST}:${O_PORT}"

MODEL="${OLLAMA_CLAUDE_MODEL:-qwen3-coder}"
ENV_HELPER="${ROOT_DIR}/scripts/claude_ollama_env.sh"

log() { echo "[setup_ollama_claude] $*"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

is_service_enabled() {
  systemctl is-enabled ollama >/dev/null 2>&1
}

is_service_active() {
  systemctl is-active ollama >/dev/null 2>&1
}

ensure_prereqs() {
  if need_cmd apt-get; then
    log "Installing prerequisites (curl, ca-certificates) via apt..."
    sudo apt-get update -y
    sudo apt-get install -y curl ca-certificates
  else
    log "apt-get not found; please ensure curl and ca-certificates are installed."
  fi
}

install_ollama_if_missing() {
  if need_cmd ollama; then
    log "Ollama already installed: $(ollama -v || true)"
    return 0
  fi
  log "Ollama not found. Installing via official installer..."
  ensure_prereqs
  curl -fsSL https://ollama.com/install.sh | sh
  if ! need_cmd ollama; then
    log "ERROR: Ollama install finished but 'ollama' still not found in PATH."
    exit 1
  fi
  log "Ollama installed: $(ollama -v || true)"
}

create_systemd_unit_if_missing() {
  # If the installer didn't provide a unit, create one aligned with Ollama docs.
  if systemctl list-unit-files | grep -qE '^ollama\.service\s'; then
    return 0
  fi

  log "ollama.service not found. Creating a systemd unit (requires sudo)..."
  local OLLAMA_BIN
  OLLAMA_BIN="$(command -v ollama)"

  # Create service user/group if needed
  if ! id -u ollama >/dev/null 2>&1; then
    log "Creating system user 'ollama'..."
    sudo useradd -r -s /bin/false -U -m -d /usr/share/ollama ollama || true
  fi

  # Create systemd unit
  sudo tee /etc/systemd/system/ollama.service >/dev/null <<EOF
[Unit]
Description=Ollama Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ollama
Group=ollama
Environment=OLLAMA_HOST=${O_HOST}:${O_PORT}
ExecStart=${OLLAMA_BIN} serve
Restart=always
RestartSec=3

# Hardening (safe defaults)
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  log "Created /etc/systemd/system/ollama.service"
}

start_ollama_systemd() {
  if ! need_cmd systemctl; then
    log "ERROR: systemctl not available. This script expects systemd for background mode."
    log "If you're in a non-systemd environment, run 'ollama serve' in a separate session."
    exit 1
  fi

  # Create unit if missing (some installs may not ship the unit)
  create_systemd_unit_if_missing

  if is_service_enabled && is_service_active; then
    log "Ollama service already enabled and active. Skipping enable/start."
  else
    if ! is_service_enabled; then
      log "Enabling Ollama systemd service..."
      sudo systemctl enable ollama
    else
      log "Ollama service already enabled."
    fi

    if ! is_service_active; then
      log "Starting Ollama systemd service..."
      sudo systemctl start ollama
    else
      log "Ollama service already active."
    fi
  fi

  log "Checking Ollama service status..."
  systemctl status ollama --no-pager || true
}

wait_for_ollama() {
  local timeout="${OLLAMA_WAIT_TIMEOUT_SEC:-60}"
  local start_ts
  start_ts="$(date +%s)"

  log "Waiting for Ollama to respond at ${O_URL} (timeout ${timeout}s)..."
  while true; do
    if curl -fsS "${O_URL}/api/tags" >/dev/null 2>&1; then
      log "Ollama is responding."
      return 0
    fi
    local now
    now="$(date +%s)"
    if (( now - start_ts >= timeout )); then
      log "ERROR: Ollama did not respond within ${timeout}s."
      log "Try: sudo systemctl status ollama --no-pager"
      log "Logs: journalctl -u ollama --no-pager --pager-end"
      exit 1
    fi
    sleep 2
  done
}

INSTALLED_MODELS=""

refresh_installed_models() {
  INSTALLED_MODELS="$(ollama list | awk 'NR>1 {print $1}')"
}

has_model_tag() {
  local tag="$1"
  grep -Fxq "${tag}" <<< "${INSTALLED_MODELS}"
}

has_model_alias() {
  local alias="$1"
  awk -v name="${alias}" '
    $0 == name || index($0, name ":") == 1 { found=1 }
    END { exit (found ? 0 : 1) }
  ' <<< "${INSTALLED_MODELS}"
}

ensure_models_and_aliases() {
  log "Checking installed Ollama models..."
  refresh_installed_models

  if has_model_tag "qwen3-coder:30b"; then
    log "Model already present: qwen3-coder:30b (skip pull)"
  else
    log "Pulling model: qwen3-coder:30b"
    ollama pull qwen3-coder:30b
    refresh_installed_models
  fi

  if has_model_tag "qwen3-coder-next:latest"; then
    log "Model already present: qwen3-coder-next:latest (skip pull)"
  else
    log "Pulling model: qwen3-coder-next:latest"
    ollama pull qwen3-coder-next:latest
    refresh_installed_models
  fi

  # Keep support for a custom Claude model override.
  if [[ "${MODEL}" != "qwen3-coder" && "${MODEL}" != "qwen3-coder-next" ]]; then
    if has_model_alias "${MODEL}"; then
      log "Custom Claude model already present: ${MODEL} (skip pull)"
    else
      log "Pulling custom Claude model override: ${MODEL}"
      ollama pull "${MODEL}"
      refresh_installed_models
    fi
  fi

  if has_model_alias "qwen3-coder"; then
    log "Alias already present: qwen3-coder (skip copy)"
  else
    log "Applying alias: ollama cp qwen3-coder:30b qwen3-coder"
    ollama cp qwen3-coder:30b qwen3-coder
    refresh_installed_models
  fi

  if has_model_alias "qwen3-coder-next"; then
    log "Alias already present: qwen3-coder-next (skip copy)"
  else
    log "Applying alias: ollama cp qwen3-coder-next:latest qwen3-coder-next"
    ollama cp qwen3-coder-next:latest qwen3-coder-next
    refresh_installed_models
  fi

  if ! has_model_alias "qwen3-coder"; then
    log "ERROR: alias 'qwen3-coder' not found after alias setup."
    exit 1
  fi
  if ! has_model_alias "qwen3-coder-next"; then
    log "ERROR: alias 'qwen3-coder-next' not found after alias setup."
    exit 1
  fi

  log "Installed models:"
  ollama list
}

write_env_helper() {
  log "Writing Claude Code env helper: ${ENV_HELPER}"
  cat > "${ENV_HELPER}" <<EOF
#!/usr/bin/env bash
# Generated by scripts/setup_ollama_claude.sh
# Usage:
#   source scripts/claude_ollama_env.sh
#   claude --model ${MODEL}

export ANTHROPIC_AUTH_TOKEN=ollama
export ANTHROPIC_API_KEY=""
export ANTHROPIC_BASE_URL=${O_URL}
EOF
  chmod +x "${ENV_HELPER}"
}

check_claude_cli() {
  if need_cmd claude; then
    log "Claude CLI detected: $(claude --version 2>/dev/null || true)"
  else
    log "Claude CLI not found."
    log "Install it (once) with:"
    log "  curl -fsSL https://claude.ai/install.sh | bash"
  fi
}

main() {
  install_ollama_if_missing
  start_ollama_systemd
  wait_for_ollama
  ensure_models_and_aliases
  write_env_helper
  check_claude_cli
  log "Done."
  log "Next:"
  log "  source scripts/claude_ollama_env.sh"
  log "  claude --model ${MODEL}"
  log "  ollama launch openclaw"
}

main "$@"
