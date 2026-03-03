#!/usr/bin/env bash
set -euo pipefail

# setup_ollama_claude.sh
#
# Goal:
# - Ensure Ollama is installed
# - Ensure Ollama is running as a *background* systemd service
# - Pull required qwen3-coder source models
# - Create local aliases used by Claude
# - Ensure Node.js/npm exist for `ollama launch openclaw` (Node >= 22)
# - Configure OpenClaw PM model provider against local vLLM-compatible endpoint
# - Warm up qwen3-coder so coding-agent model is loaded into GPU VRAM
# - Optionally auto-launch OpenClaw TUI for daily usage
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
NPM_GLOBAL_PREFIX="${NPM_GLOBAL_PREFIX:-${HOME}/.local}"
OPENCLAW_PM_CONFIGURE="${OPENCLAW_PM_CONFIGURE:-1}"
OPENCLAW_PM_BASE_URL="${OPENCLAW_PM_BASE_URL:-http://127.0.0.1:8000/v1}"
OPENCLAW_PM_PROVIDER_ID="${OPENCLAW_PM_PROVIDER_ID:-vllm}"
OPENCLAW_PM_API_KEY="${OPENCLAW_PM_API_KEY:-vllm-local}"
OPENCLAW_PM_API_ADAPTER="${OPENCLAW_PM_API_ADAPTER:-openai-completions}"
OPENCLAW_PM_MODEL_NAME="${OPENCLAW_PM_MODEL_NAME:-PM Nemotron}"
OPENCLAW_PM_CONTEXT_WINDOW="${OPENCLAW_PM_CONTEXT_WINDOW:-262144}"
OPENCLAW_PM_MAX_TOKENS="${OPENCLAW_PM_MAX_TOKENS:-8192}"
OPENCLAW_BOOTSTRAP_WITH_OLLAMA="${OPENCLAW_BOOTSTRAP_WITH_OLLAMA:-1}"
OPENCLAW_MANAGE_GATEWAY="${OPENCLAW_MANAGE_GATEWAY:-1}"
OPENCLAW_SYNC_MAIN_SESSION_MODEL="${OPENCLAW_SYNC_MAIN_SESSION_MODEL:-1}"
OPENCLAW_GATEWAY_RESTART_IF_RUNNING="${OPENCLAW_GATEWAY_RESTART_IF_RUNNING:-1}"
CODING_MODEL_WARMUP="${CODING_MODEL_WARMUP:-1}"
CODING_MODEL_WARMUP_PROMPT="${CODING_MODEL_WARMUP_PROMPT:-Warmup ping. Reply with exactly: OK}"
OPENCLAW_AUTO_TUI="${OPENCLAW_AUTO_TUI:-1}"

log() { echo "[setup_ollama_claude] $*"; }

script_is_sourced() {
  [[ "${BASH_SOURCE[0]}" != "$0" ]]
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

is_truthy() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

node_major_version() {
  if ! need_cmd node; then
    return 1
  fi
  node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/'
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

install_or_upgrade_nodejs() {
  if ! need_cmd apt-get; then
    log "ERROR: apt-get not found. Install Node.js >= 22 and npm manually for OpenClaw."
    exit 1
  fi
  ensure_prereqs
  log "Installing/upgrading Node.js 22.x + npm via NodeSource..."
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
  sudo apt-get install -y nodejs
}

ensure_node_npm_for_openclaw() {
  local required_major=22
  local node_major=""

  if need_cmd node; then
    node_major="$(node_major_version || true)"
  fi

  if [[ -n "${node_major}" ]] && (( node_major >= required_major )) && need_cmd npm; then
    log "Node.js/npm already satisfy OpenClaw prerequisite: $(node -v) / npm $(npm -v)"
    return 0
  fi

  if [[ -z "${node_major}" ]]; then
    log "Node.js is not installed; required for 'ollama launch openclaw'."
  elif (( node_major < required_major )); then
    log "Node.js $(node -v) detected, but OpenClaw requires Node >= ${required_major}."
  fi
  if ! need_cmd npm; then
    log "npm is not installed; required for OpenClaw install."
  fi

  install_or_upgrade_nodejs

  if ! need_cmd node || ! need_cmd npm; then
    log "ERROR: Node.js/npm installation did not complete successfully."
    exit 1
  fi

  node_major="$(node_major_version || true)"
  if [[ -z "${node_major}" ]] || (( node_major < required_major )); then
    log "ERROR: Node.js version is still below ${required_major}: $(node -v || true)"
    exit 1
  fi

  log "Node.js/npm ready for OpenClaw: $(node -v) / npm $(npm -v)"
}

path_has_dir() {
  local target="$1"
  [[ ":${PATH}:" == *":${target}:"* ]]
}

ensure_npm_global_prefix_writable() {
  if ! need_cmd npm; then
    log "ERROR: npm not found while checking npm global prefix."
    exit 1
  fi

  local prefix=""
  prefix="$(npm config get prefix 2>/dev/null || true)"
  if [[ -z "${prefix}" || "${prefix}" == "undefined" ]]; then
    log "ERROR: failed to read npm global prefix."
    exit 1
  fi

  if [[ -d "${prefix}" && -w "${prefix}" ]]; then
    log "npm global prefix is writable: ${prefix}"
  else
    log "npm global prefix is not writable (${prefix}); switching to user prefix: ${NPM_GLOBAL_PREFIX}"
    mkdir -p "${NPM_GLOBAL_PREFIX}"
    npm config set prefix "${NPM_GLOBAL_PREFIX}"
    prefix="$(npm config get prefix 2>/dev/null || true)"
    if [[ -z "${prefix}" || ! -d "${prefix}" || ! -w "${prefix}" ]]; then
      log "ERROR: failed to set a writable npm global prefix."
      exit 1
    fi
    log "npm global prefix updated: ${prefix}"
  fi

  local npm_bin_dir
  npm_bin_dir="${prefix}/bin"
  if ! path_has_dir "${npm_bin_dir}"; then
    log "WARNING: ${npm_bin_dir} is not in PATH for this shell."
    log "Add this line to your shell rc (~/.bashrc or ~/.zshrc):"
    log "  export PATH=\"${npm_bin_dir}:\$PATH\""
  fi
}

OPENCLAW_CMD=""

resolve_openclaw_cmd() {
  OPENCLAW_CMD=""
  if need_cmd openclaw; then
    OPENCLAW_CMD="$(command -v openclaw)"
    return 0
  fi
  if [[ -x "${NPM_GLOBAL_PREFIX}/bin/openclaw" ]]; then
    OPENCLAW_CMD="${NPM_GLOBAL_PREFIX}/bin/openclaw"
    return 0
  fi
  return 1
}

resolve_openclaw_config_path() {
  if ! resolve_openclaw_cmd; then
    return 1
  fi

  local raw_path=""
  raw_path="$("${OPENCLAW_CMD}" config file 2>/dev/null | tail -n1 | tr -d '\r' || true)"
  if [[ -z "${raw_path}" ]]; then
    return 1
  fi

  if [[ "${raw_path}" == "Config file not found: "* ]]; then
    raw_path="${raw_path#Config file not found: }"
  fi
  if [[ "${raw_path}" == "~/"* ]]; then
    raw_path="${HOME}/${raw_path#\~/}"
  fi

  printf "%s\n" "${raw_path}"
}

openclaw_config_exists() {
  local candidates=()
  local config_path=""
  local candidate=""

  if [[ -n "${OPENCLAW_CONFIG_PATH:-}" ]]; then
    candidates+=("${OPENCLAW_CONFIG_PATH}")
  fi

  config_path="$(resolve_openclaw_config_path || true)"
  if [[ -n "${config_path}" ]]; then
    candidates+=("${config_path}")
  fi

  # Fallback defaults used by OpenClaw profiles.
  candidates+=(
    "${HOME}/.openclaw/openclaw.json"
    "${HOME}/.openclaw-dev/openclaw.json"
  )

  for candidate in "${candidates[@]}"; do
    if [[ "${candidate}" == "~/"* ]]; then
      candidate="${HOME}/${candidate#\~/}"
    fi
    if [[ -f "${candidate}" ]]; then
      return 0
    fi
  done
  return 1
}

ensure_openclaw_cli_for_config() {
  if resolve_openclaw_cmd && openclaw_config_exists; then
    return 0
  fi

  if ! is_truthy "${OPENCLAW_BOOTSTRAP_WITH_OLLAMA}"; then
    log "WARNING: OpenClaw bootstrap via Ollama is disabled (OPENCLAW_BOOTSTRAP_WITH_OLLAMA=${OPENCLAW_BOOTSTRAP_WITH_OLLAMA})."
    log "Skipping OpenClaw bootstrap/config."
    return 1
  fi

  if [[ -t 0 && -t 1 ]]; then
    log "OpenClaw bootstrap required. Running 'ollama launch openclaw --config' (first-time only)..."
    if ollama launch openclaw --config; then
      if resolve_openclaw_cmd && openclaw_config_exists; then
        return 0
      fi
    fi
    log "WARNING: OpenClaw bootstrap/config did not complete via ollama launcher."
  else
    log "WARNING: OpenClaw bootstrap required but no interactive TTY is available."
  fi

  log "WARNING: skipping OpenClaw PM provider config for now."
  log "Run this once in an interactive terminal, then rerun setup:"
  log "  ollama launch openclaw --config"
  return 1
}

detect_pm_model_id_from_endpoint() {
  local models_url="${OPENCLAW_PM_BASE_URL%/}/models"
  curl -fsS "${models_url}" | node -e '
    let payload = "";
    process.stdin.on("data", (chunk) => {
      payload += chunk;
    });
    process.stdin.on("end", () => {
      try {
        const parsed = JSON.parse(payload);
        const candidates = Array.isArray(parsed)
          ? parsed
          : Array.isArray(parsed.data)
            ? parsed.data
            : Array.isArray(parsed.models)
              ? parsed.models
              : [];
        const first = candidates.find((item) => item && typeof item.id === "string" && item.id.trim().length > 0);
        if (!first) {
          process.exit(2);
        }
        process.stdout.write(first.id.trim());
      } catch {
        process.exit(3);
      }
    });
  '
}

build_openclaw_provider_json() {
  local model_id="$1"
  node -e '
    const [baseUrl, apiKey, api, modelId, modelName, contextWindowRaw, maxTokensRaw] = process.argv.slice(1);
    const contextWindow = Number.parseInt(contextWindowRaw, 10);
    const maxTokens = Number.parseInt(maxTokensRaw, 10);
    if (!Number.isInteger(contextWindow) || contextWindow <= 0 || !Number.isInteger(maxTokens) || maxTokens <= 0) {
      process.exit(2);
    }
    const payload = {
      baseUrl,
      apiKey,
      api,
      models: [
        {
          id: modelId,
          name: modelName,
          reasoning: true,
          input: ["text"],
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
          contextWindow,
          maxTokens,
        },
      ],
    };
    process.stdout.write(JSON.stringify(payload));
  ' \
    "${OPENCLAW_PM_BASE_URL}" \
    "${OPENCLAW_PM_API_KEY}" \
    "${OPENCLAW_PM_API_ADAPTER}" \
    "${model_id}" \
    "${OPENCLAW_PM_MODEL_NAME}" \
    "${OPENCLAW_PM_CONTEXT_WINDOW}" \
    "${OPENCLAW_PM_MAX_TOKENS}"
}

configure_openclaw_pm_provider() {
  if ! is_truthy "${OPENCLAW_PM_CONFIGURE}"; then
    log "Skipping OpenClaw PM provider config (OPENCLAW_PM_CONFIGURE=${OPENCLAW_PM_CONFIGURE})."
    return 0
  fi

  if ! need_cmd curl; then
    log "WARNING: curl not available; skipping OpenClaw PM provider config."
    return 0
  fi
  if ! need_cmd node; then
    log "WARNING: node not available; skipping OpenClaw PM provider config."
    return 0
  fi

  local pm_model_id=""
  pm_model_id="$(detect_pm_model_id_from_endpoint || true)"
  if [[ -z "${pm_model_id}" ]]; then
    log "WARNING: PM endpoint is not ready at ${OPENCLAW_PM_BASE_URL%/}/models; skipping OpenClaw PM provider config."
    log "Start NIM/vLLM first, then rerun this setup."
    return 0
  fi
  log "Detected PM model id from endpoint: ${pm_model_id}"

  if ! ensure_openclaw_cli_for_config; then
    return 0
  fi

  local provider_json=""
  provider_json="$(build_openclaw_provider_json "${pm_model_id}" || true)"
  if [[ -z "${provider_json}" ]]; then
    log "ERROR: failed to build OpenClaw provider JSON payload."
    exit 1
  fi

  "${OPENCLAW_CMD}" config set "models.providers.${OPENCLAW_PM_PROVIDER_ID}" "${provider_json}" --strict-json
  "${OPENCLAW_CMD}" config set "agents.defaults.model.primary" "${OPENCLAW_PM_PROVIDER_ID}/${pm_model_id}"
  "${OPENCLAW_CMD}" config validate >/dev/null

  local config_file
  config_file="$("${OPENCLAW_CMD}" config file 2>/dev/null || true)"
  log "OpenClaw PM provider configured: ${OPENCLAW_PM_PROVIDER_ID}/${pm_model_id} -> ${OPENCLAW_PM_BASE_URL}"
  if [[ -n "${config_file}" ]]; then
    log "OpenClaw config file: ${config_file}"
  fi
}

ensure_openclaw_gateway_running() {
  if ! is_truthy "${OPENCLAW_MANAGE_GATEWAY}"; then
    log "Skipping OpenClaw gateway management (OPENCLAW_MANAGE_GATEWAY=${OPENCLAW_MANAGE_GATEWAY})."
    return 0
  fi

  if ! resolve_openclaw_cmd; then
    log "WARNING: OpenClaw CLI not found; skipping gateway management."
    return 0
  fi
  if ! openclaw_config_exists; then
    log "WARNING: OpenClaw config file is missing; skipping gateway management."
    return 0
  fi

  local status_output=""
  status_output="$("${OPENCLAW_CMD}" gateway status 2>/dev/null || true)"
  if grep -q "Runtime: running" <<< "${status_output}"; then
    if is_truthy "${OPENCLAW_GATEWAY_RESTART_IF_RUNNING}"; then
      log "OpenClaw gateway is running; restarting to apply latest config/session defaults..."
      "${OPENCLAW_CMD}" gateway restart >/dev/null 2>&1 || {
        log "WARNING: failed to restart OpenClaw gateway service."
      }
      log "OpenClaw gateway service restarted."
    else
      log "OpenClaw gateway already running."
    fi
    return 0
  fi

  log "Starting/restarting OpenClaw gateway service..."
  if ! "${OPENCLAW_CMD}" gateway start >/dev/null 2>&1; then
    "${OPENCLAW_CMD}" gateway restart >/dev/null 2>&1 || {
      log "WARNING: failed to start/restart OpenClaw gateway service."
      return 0
    }
  fi
  log "OpenClaw gateway service is running."
}

sync_openclaw_main_session_model() {
  if ! is_truthy "${OPENCLAW_SYNC_MAIN_SESSION_MODEL}"; then
    log "Skipping OpenClaw main-session model sync (OPENCLAW_SYNC_MAIN_SESSION_MODEL=${OPENCLAW_SYNC_MAIN_SESSION_MODEL})."
    return 0
  fi

  if ! resolve_openclaw_cmd; then
    log "WARNING: OpenClaw CLI not found; skipping main-session model sync."
    return 0
  fi
  if ! openclaw_config_exists; then
    log "WARNING: OpenClaw config file is missing; skipping main-session model sync."
    return 0
  fi
  if ! need_cmd node; then
    log "WARNING: node not available; skipping main-session model sync."
    return 0
  fi

  local default_model_ref=""
  default_model_ref="$("${OPENCLAW_CMD}" config get agents.defaults.model.primary --json 2>/dev/null | node -e '
    let text = "";
    process.stdin.on("data", (d) => { text += d; });
    process.stdin.on("end", () => {
      try {
        const parsed = JSON.parse(text);
        if (typeof parsed === "string" && parsed.trim()) {
          process.stdout.write(parsed.trim());
          return;
        }
      } catch {}
      process.exit(2);
    });
  ' || true)"
  if [[ -z "${default_model_ref}" ]]; then
    log "WARNING: unable to resolve OpenClaw default model; skipping main-session model sync."
    return 0
  fi

  local provider="${default_model_ref%%/*}"
  local model="${default_model_ref#*/}"
  if [[ -z "${provider}" || -z "${model}" || "${provider}" == "${default_model_ref}" ]]; then
    log "WARNING: default model ref is invalid (${default_model_ref}); skipping main-session model sync."
    return 0
  fi

  local config_path=""
  config_path="$(resolve_openclaw_config_path || true)"
  if [[ -z "${config_path}" ]]; then
    config_path="${HOME}/.openclaw/openclaw.json"
  fi
  if [[ "${config_path}" == "~/"* ]]; then
    config_path="${HOME}/${config_path#\~/}"
  fi
  local state_dir
  state_dir="$(dirname "${config_path}")"
  local session_store="${state_dir}/agents/main/sessions/sessions.json"

  if [[ ! -f "${session_store}" ]]; then
    log "OpenClaw session store not found at ${session_store}; skipping main-session model sync."
    return 0
  fi

  local sync_result=""
  sync_result="$(node -e '
    const fs = require("fs");
    const [path, provider, model] = process.argv.slice(1);
    let raw;
    try {
      raw = fs.readFileSync(path, "utf8");
    } catch (err) {
      process.stderr.write(`read-error:${err?.message || err}\n`);
      process.exit(2);
    }
    let data;
    try {
      data = JSON.parse(raw);
    } catch (err) {
      process.stderr.write(`json-error:${err?.message || err}\n`);
      process.exit(3);
    }
    const key = "agent:main:main";
    if (!data || typeof data !== "object" || !data[key] || typeof data[key] !== "object") {
      process.stdout.write("missing");
      process.exit(0);
    }
    const entry = data[key];
    const beforeProvider = typeof entry.modelProvider === "string" ? entry.modelProvider : "";
    const beforeModel = typeof entry.model === "string" ? entry.model : "";
    if (beforeProvider === provider && beforeModel === model && entry.modelOverride === undefined && entry.providerOverride === undefined) {
      process.stdout.write("unchanged");
      process.exit(0);
    }
    entry.modelProvider = provider;
    entry.model = model;
    delete entry.modelOverride;
    delete entry.providerOverride;
    fs.writeFileSync(path, `${JSON.stringify(data, null, 2)}\n`, "utf8");
    process.stdout.write(`updated:${beforeProvider}/${beforeModel}->${provider}/${model}`);
  ' "${session_store}" "${provider}" "${model}" 2>/dev/null || true)"

  case "${sync_result}" in
    updated:*)
      log "Synchronized OpenClaw main session model (${sync_result#updated:})."
      ;;
    unchanged)
      log "OpenClaw main session already matches default model (${default_model_ref})."
      ;;
    missing)
      log "OpenClaw main session entry not found; it will inherit default model (${default_model_ref}) on next new session."
      ;;
    *)
      log "WARNING: unable to sync OpenClaw main session model."
      ;;
  esac
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

load_env_helper() {
  if [[ ! -f "${ENV_HELPER}" ]]; then
    log "ERROR: env helper not found: ${ENV_HELPER}"
    exit 1
  fi
  # shellcheck source=/dev/null
  source "${ENV_HELPER}"
  log "Loaded Claude env helper for this setup run."
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

build_ollama_generate_payload() {
  local model="$1"
  local prompt="$2"
  node -e '
    const [model, prompt] = process.argv.slice(1);
    process.stdout.write(JSON.stringify({
      model,
      prompt,
      stream: false,
      options: { num_predict: 16, temperature: 0 },
    }));
  ' "${model}" "${prompt}"
}

warmup_coding_model() {
  if ! is_truthy "${CODING_MODEL_WARMUP}"; then
    log "Skipping coding-model warmup (CODING_MODEL_WARMUP=${CODING_MODEL_WARMUP})."
    return 0
  fi

  local warmed=0
  if need_cmd claude; then
    log "Warming up coding model via Claude print mode: ${MODEL}"
    if claude --model "${MODEL}" --tools "" --print "${CODING_MODEL_WARMUP_PROMPT}" >/dev/null 2>&1; then
      warmed=1
    else
      log "WARNING: Claude warmup failed; falling back to Ollama API warmup."
    fi
  fi

  if [[ "${warmed}" -eq 0 ]]; then
    if ! need_cmd curl; then
      log "WARNING: curl not found; unable to warm up coding model."
      return 0
    fi
    if ! need_cmd node; then
      log "WARNING: node not found; unable to build warmup payload."
      return 0
    fi

    log "Warming up coding model via Ollama API: ${MODEL}"
    local payload=""
    payload="$(build_ollama_generate_payload "${MODEL}" "${CODING_MODEL_WARMUP_PROMPT}" || true)"
    if [[ -z "${payload}" ]]; then
      log "WARNING: failed to build Ollama warmup payload."
      return 0
    fi
    if curl -fsS "${O_URL}/api/generate" \
      -H "Content-Type: application/json" \
      --data-binary "${payload}" >/dev/null 2>&1; then
      warmed=1
    fi
  fi

  if [[ "${warmed}" -eq 1 ]]; then
    log "Coding model warmup complete (${MODEL} loaded)."
  else
    log "WARNING: coding model warmup did not complete successfully."
  fi
}

maybe_launch_openclaw_tui() {
  if ! is_truthy "${OPENCLAW_AUTO_TUI}"; then
    log "Skipping auto TUI launch (OPENCLAW_AUTO_TUI=${OPENCLAW_AUTO_TUI})."
    return 0
  fi
  if [[ ! -t 0 || ! -t 1 ]]; then
    log "Skipping auto TUI launch (no interactive TTY)."
    return 0
  fi
  if ! resolve_openclaw_cmd; then
    log "WARNING: OpenClaw CLI not found; cannot auto-launch TUI."
    return 0
  fi
  log "Launching OpenClaw TUI..."
  exec "${OPENCLAW_CMD}" tui
}

main() {
  ensure_node_npm_for_openclaw
  ensure_npm_global_prefix_writable
  install_ollama_if_missing
  start_ollama_systemd
  wait_for_ollama
  ensure_models_and_aliases
  write_env_helper
  load_env_helper
  warmup_coding_model
  configure_openclaw_pm_provider
  sync_openclaw_main_session_model
  ensure_openclaw_gateway_running
  check_claude_cli
  log "Done."
  if ! script_is_sourced; then
    log "To load Claude env in your current shell:"
    log "  source scripts/claude_ollama_env.sh"
  fi
  log "Next:"
  log "  claude --model ${MODEL}"
  log "  openclaw tui"
  log "Workflow:"
  log "  - Use 'ollama launch openclaw' only for first-time bootstrap."
  log "  - For daily use, use 'openclaw tui' (or 'openclaw gateway start/restart')."
  log "  - If you run 'ollama launch openclaw' again, rerun this script to re-assert PM model config."
  maybe_launch_openclaw_tui
}

main "$@"
