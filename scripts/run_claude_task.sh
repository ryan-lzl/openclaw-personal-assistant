#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/run_claude_task.sh <packet.md>

Required packet fields:
  Web Search: off|optional|required
  Subagents Min: 2..10
  Subagents Max: 2..10

Env overrides:
  OLLAMA_BASE_URL   (default: http://127.0.0.1:11434)
  CLAUDE_MODEL      (default: qwen3-coder)
  WEB_SEARCH_CLOUD_MODEL (default: minimax-m2.5:cloud)
  WEB_SEARCH_MODE   (default: auto)
                    auto     -> read "Web Search: ..." from packet, else off
                    off      -> explicitly disable web search
                    optional -> allow web search if runtime supports it
                    required -> force web search; requires a :cloud model
EOF
}

PACKET_FILE="${1:-}"
if [[ $# -ne 1 || -z "${PACKET_FILE}" || ! -f "${PACKET_FILE}" ]]; then
  usage
  exit 1
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command not found: $1" >&2
    exit 1
  fi
}

normalize_mode() {
  local raw="${1:-}"
  raw="$(echo "${raw}" | tr '[:upper:]' '[:lower:]' | xargs)"
  case "${raw}" in
    auto|"") echo "auto" ;;
    off|none|disabled|false|no) echo "off" ;;
    optional|on|true|yes) echo "optional" ;;
    required|must|mandatory) echo "required" ;;
    *)
      echo "Error: unsupported web search mode: ${raw}" >&2
      exit 1
      ;;
  esac
}

is_cloud_model() {
  local model="${1:-}"
  [[ "${model}" == *":cloud" ]]
}

packet_field() {
  local field_name="${1:-}"
  awk -F: -v field_name="${field_name}" '
    BEGIN { IGNORECASE=1 }
    {
      key = $1
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      if (tolower(key) != tolower(field_name)) {
        next
      }
      value = substr($0, index($0, ":") + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      print value
      exit
    }
  ' "${PACKET_FILE}" || true
}

parse_subagent_bound() {
  local field_name="${1:-}"
  local raw_value="${2:-}"

  if [[ -z "${raw_value}" ]]; then
    echo "Error: packet is missing required field '${field_name}'." >&2
    echo "Add both 'Subagents Min:' and 'Subagents Max:' to the packet." >&2
    exit 1
  fi

  if ! [[ "${raw_value}" =~ ^[0-9]+$ ]]; then
    echo "Error: '${field_name}' must be an integer. Got: ${raw_value}" >&2
    exit 1
  fi

  local value=$((10#${raw_value}))
  if (( value < 2 || value > 10 )); then
    echo "Error: '${field_name}' must be between 2 and 10. Got: ${value}" >&2
    exit 1
  fi

  echo "${value}"
}

require_cmd claude
require_cmd curl

OLLAMA_BASE_URL="${OLLAMA_BASE_URL:-http://127.0.0.1:11434}"
CLAUDE_MODEL="${CLAUDE_MODEL:-qwen3-coder}"
WEB_SEARCH_CLOUD_MODEL="${WEB_SEARCH_CLOUD_MODEL:-minimax-m2.5:cloud}"
WEB_SEARCH_MODE="$(normalize_mode "${WEB_SEARCH_MODE:-auto}")"

# Claude Code -> Ollama Anthropic compatibility defaults.
export ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-ollama}"
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
export ANTHROPIC_BASE_URL="${ANTHROPIC_BASE_URL:-${OLLAMA_BASE_URL}}"

if ! curl -fsS "${OLLAMA_BASE_URL}/api/tags" >/dev/null 2>&1; then
  echo "Error: Ollama not reachable at ${OLLAMA_BASE_URL}" >&2
  exit 1
fi

PACKET_WEB_SEARCH_MODE="$(packet_field "Web Search")"
if [[ -z "${PACKET_WEB_SEARCH_MODE}" ]]; then
  echo "Error: packet is missing required field 'Web Search:'." >&2
  echo "Set it to one of: off, optional, required." >&2
  exit 1
fi
PACKET_WEB_SEARCH_MODE="$(normalize_mode "${PACKET_WEB_SEARCH_MODE}")"
PACKET_WEB_SEARCH_MODEL="$(packet_field "Web Search Model")"
if [[ -n "${PACKET_WEB_SEARCH_MODEL}" ]]; then
  WEB_SEARCH_CLOUD_MODEL="${PACKET_WEB_SEARCH_MODEL}"
fi

SUBAGENTS_MIN_RAW="$(packet_field "Subagents Min")"
SUBAGENTS_MAX_RAW="$(packet_field "Subagents Max")"
SUBAGENTS_MIN="$(parse_subagent_bound "Subagents Min" "${SUBAGENTS_MIN_RAW}")"
SUBAGENTS_MAX="$(parse_subagent_bound "Subagents Max" "${SUBAGENTS_MAX_RAW}")"

if (( SUBAGENTS_MIN > SUBAGENTS_MAX )); then
  echo "Error: 'Subagents Min' cannot be greater than 'Subagents Max'." >&2
  echo "Got: Subagents Min=${SUBAGENTS_MIN}, Subagents Max=${SUBAGENTS_MAX}" >&2
  exit 1
fi

if [[ "${WEB_SEARCH_MODE}" == "auto" ]]; then
  if [[ -n "${PACKET_WEB_SEARCH_MODE}" && "${PACKET_WEB_SEARCH_MODE}" != "auto" ]]; then
    WEB_SEARCH_MODE="${PACKET_WEB_SEARCH_MODE}"
  else
    WEB_SEARCH_MODE="off"
  fi
fi

if [[ "${WEB_SEARCH_MODE}" == "required" ]] && ! is_cloud_model "${CLAUDE_MODEL}"; then
  if is_cloud_model "${WEB_SEARCH_CLOUD_MODEL}"; then
    echo "Info: web search required; switching model to ${WEB_SEARCH_CLOUD_MODEL}." >&2
    CLAUDE_MODEL="${WEB_SEARCH_CLOUD_MODEL}"
  else
    cat >&2 <<EOF
Error: web search is required but no valid cloud model is configured.
Current CLAUDE_MODEL='${CLAUDE_MODEL}' and WEB_SEARCH_CLOUD_MODEL='${WEB_SEARCH_CLOUD_MODEL}'.
Set WEB_SEARCH_CLOUD_MODEL (or packet field 'Web Search Model') to a value ending in ':cloud'.
EOF
    exit 1
  fi
fi

if [[ "${WEB_SEARCH_MODE}" == "optional" ]] && ! is_cloud_model "${CLAUDE_MODEL}"; then
  echo "Warning: optional web search requested with local model (${CLAUDE_MODEL})." >&2
  echo "         Search may be unavailable unless you configured a search MCP/tool." >&2
fi

PACKET_CONTENT="$(cat "${PACKET_FILE}")"

if [[ "${WEB_SEARCH_MODE}" == "required" ]]; then
  WEB_SEARCH_BLOCK="$(cat <<'EOF'
## Web search (MANDATORY)
Use web search for all time-sensitive or external facts.
- Include source URLs.
- Include retrieval date in YYYY-MM-DD format.
- If a source is inaccessible, say so explicitly and continue with available evidence.
EOF
)"
elif [[ "${WEB_SEARCH_MODE}" == "optional" ]]; then
  WEB_SEARCH_BLOCK="$(cat <<'EOF'
## Web search (OPTIONAL)
Use web search when the task depends on external or recent information.
- Include source URLs for all externally sourced claims.
- Include retrieval date in YYYY-MM-DD format.
EOF
)"
else
  WEB_SEARCH_BLOCK="$(cat <<'EOF'
## Web search (DISABLED)
Do not use external web search for this task. Work from repo context and local execution.
EOF
)"
fi

PROMPT="$(cat <<EOF
${PACKET_CONTENT}

## Subagent instruction (MANDATORY)
Create between ${SUBAGENTS_MIN} and ${SUBAGENTS_MAX} subagents to parallelize:
1) Relevant files and entrypoints
2) Test mapping and run strategy
3) Existing patterns/conventions to follow

Select the exact number based on complexity and explain why that count is appropriate.
Each subagent must return concise findings before implementation begins.

${WEB_SEARCH_BLOCK}

## Output contract (MANDATORY)
Return:
1) Summary of what changed
2) Files changed
3) Commands run
4) Test results
5) Risks or follow-ups
EOF
)"

echo "Launching Claude Code"
echo "  packet: ${PACKET_FILE}"
echo "  model: ${CLAUDE_MODEL}"
echo "  web search mode: ${WEB_SEARCH_MODE}"
echo "  subagents range: ${SUBAGENTS_MIN}-${SUBAGENTS_MAX}"

exec claude --model "${CLAUDE_MODEL}" --prompt "${PROMPT}"
