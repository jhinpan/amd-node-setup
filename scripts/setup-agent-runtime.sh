#!/usr/bin/env bash
set -Eeuo pipefail

# Configure the container-local runtime for Claude Code, Codex, and either
# local AMD gateway proxy sessions or SSH forwards to proxies on n0809. This
# runs inside the ROCm dev container after scripts/setup-dev-env.sh.

LLM_GATEWAY_API_KEY="${LLM_GATEWAY_API_KEY:-${AMD_LLM_API_KEY:-}}"
LLM_GATEWAY_BASE_URL="${LLM_GATEWAY_BASE_URL:-${AMD_LLM_BASE_URL:-https://llm-api.amd.com}}"
LLM_GATEWAY_OPENAI_BASE_URL="${LLM_GATEWAY_OPENAI_BASE_URL:-${AMD_OPENAI_BASE_URL:-${LLM_GATEWAY_BASE_URL%/}/Unified/v1}}"
# NTID attached as the `user` header on every gateway request (required for
# shared/app-level API keys).
AMD_USER_NTID="${AMD_USER_NTID:-${LLM_GATEWAY_USER_NTID:-}}"

PROXY_BACKEND="${PROXY_BACKEND:-local}"
PROXY_HOST="${PROXY_HOST:-127.0.0.1}"
CLAUDE_PROXY_PORT="${CLAUDE_PROXY_PORT:-8082}"
CODEX_PROXY_PORT="${CODEX_PROXY_PORT:-8083}"
CLAUDE_BASE_URL="${CLAUDE_BASE_URL:-http://127.0.0.1:${CLAUDE_PROXY_PORT}}"
CODEX_BASE_URL="${CODEX_BASE_URL:-http://127.0.0.1:${CODEX_PROXY_PORT}/v1}"
REMOTE_PROXY_SSH_TARGET="${REMOTE_PROXY_SSH_TARGET:-${N0809_SSH_TARGET:-}}"
REMOTE_PROXY_SSH_OPTS="${REMOTE_PROXY_SSH_OPTS:-}"
REMOTE_PROXY_START_SSH_TUNNELS="${REMOTE_PROXY_START_SSH_TUNNELS:-1}"
REMOTE_CLAUDE_PROXY_HOST="${REMOTE_CLAUDE_PROXY_HOST:-127.0.0.1}"
REMOTE_CODEX_PROXY_HOST="${REMOTE_CODEX_PROXY_HOST:-127.0.0.1}"
REMOTE_CLAUDE_PROXY_PORT="${REMOTE_CLAUDE_PROXY_PORT:-${CLAUDE_PROXY_PORT}}"
REMOTE_CODEX_PROXY_PORT="${REMOTE_CODEX_PROXY_PORT:-${CODEX_PROXY_PORT}}"

CLAUDE_MODEL="${CLAUDE_MODEL:-claude-opus-4-8}"
CLAUDE_EFFORT="${CLAUDE_EFFORT:-xhigh}"
CLAUDE_ULTRACODE="${CLAUDE_ULTRACODE:-1}"

CODEX_MODEL="${CODEX_MODEL:-gpt-5.5}"
CODEX_REASONING_EFFORT="${CODEX_REASONING_EFFORT:-xhigh}"
CODEX_REASONING_LABEL="${CODEX_REASONING_LABEL:-ultrahigh}"
CODEX_PROVIDER_ID="${CODEX_PROVIDER_ID:-amd_proxy_chat}"
CODEX_PROVIDER_NAME="${CODEX_PROVIDER_NAME:-AMD LLM Gateway via OpenAI Chat Completions}"
CODEX_PROVIDER_ENV_KEY="${CODEX_PROVIDER_ENV_KEY:-OPENAI_API_KEY}"
CODEX_PROVIDER_WIRE_API="${CODEX_PROVIDER_WIRE_API:-chat}"
CODEX_PROVIDER_HEADER_ENV_KEY="${CODEX_PROVIDER_HEADER_ENV_KEY:-}"

RUNTIME_DIR="${RUNTIME_DIR:-$HOME/.amd-node-setup}"
RUNTIME_BIN_DIR="${RUNTIME_BIN_DIR:-${RUNTIME_DIR}/bin}"
REPO_DIR="${AMD_NODE_SETUP_REPO:-${AMD_NODE_RUNTIME_REPO:-/opt/amd-node-setup}}"

if [[ -d "$HOME/.local/bin" && ":${PATH}:" != *":${HOME}/.local/bin:"* ]]; then
  export PATH="$HOME/.local/bin:$PATH"
fi

fail() {
  echo "[ERROR] $*" >&2
  exit 1
}

write_export() {
  local key="$1"
  local value="$2"
  printf 'export %s=%q\n' "$key" "$value"
}

find_real_bin() {
  local name="$1"
  local dir candidate
  IFS=: read -r -a path_parts <<< "${PATH}"
  for dir in "${path_parts[@]}"; do
    [[ -z "${dir}" ]] && dir="."
    [[ "${dir}" == "${RUNTIME_BIN_DIR}" ]] && continue
    candidate="${dir}/${name}"
    if [[ -x "${candidate}" ]]; then
      echo "${candidate}"
      return 0
    fi
  done
  return 1
}

append_once() {
  local file="$1"
  local needle="$2"
  local content="$3"
  if [[ -f "${file}" ]] && grep -Fq "${needle}" "${file}"; then
    return
  fi
  {
    echo ""
    echo "${content}"
  } >> "${file}"
}

start_tmux_session() {
  local session="$1"
  local env_file="$2"
  if ! command -v tmux >/dev/null 2>&1; then
    echo "[WARN] tmux is not installed; skipping ${session}" >&2
    return
  fi

  tmux kill-session -t "${session}" >/dev/null 2>&1 || true
  tmux new-session -d -s "${session}" \
    "set -a; . '${env_file}'; set +a; python3 '${REPO_DIR}/proxy/amd_proxy.py'"
}

write_ssh_forward_runner() {
  cat > "${RUNTIME_DIR}/start-remote-proxy-forward.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

: "${REMOTE_PROXY_SSH_TARGET:?REMOTE_PROXY_SSH_TARGET is required}"
: "${LOCAL_PROXY_PORT:?LOCAL_PROXY_PORT is required}"
: "${REMOTE_PROXY_HOST:?REMOTE_PROXY_HOST is required}"
: "${REMOTE_PROXY_PORT:?REMOTE_PROXY_PORT is required}"

ssh_opts=(
  -o ExitOnForwardFailure=yes
  -o ServerAliveInterval=30
  -o ServerAliveCountMax=3
)

if [[ -n "${REMOTE_PROXY_SSH_OPTS:-}" ]]; then
  read -r -a extra_ssh_opts <<< "${REMOTE_PROXY_SSH_OPTS}"
  ssh_opts+=("${extra_ssh_opts[@]}")
fi

exec ssh "${ssh_opts[@]}" \
  -N \
  -L "${PROXY_HOST:-127.0.0.1}:${LOCAL_PROXY_PORT}:${REMOTE_PROXY_HOST}:${REMOTE_PROXY_PORT}" \
  "${REMOTE_PROXY_SSH_TARGET}"
EOF
  chmod 700 "${RUNTIME_DIR}/start-remote-proxy-forward.sh"
}

start_ssh_forward_session() {
  local session="$1"
  local env_file="$2"

  if [[ "${REMOTE_PROXY_START_SSH_TUNNELS}" != "1" ]]; then
    echo "[WARN] REMOTE_PROXY_START_SSH_TUNNELS=${REMOTE_PROXY_START_SSH_TUNNELS}; not starting ${session}" >&2
    return
  fi
  if [[ -z "${REMOTE_PROXY_SSH_TARGET}" ]]; then
    echo "[WARN] REMOTE_PROXY_SSH_TARGET is empty; expecting direct URLs or pre-existing forwards for ${session}" >&2
    return
  fi
  if ! command -v ssh >/dev/null 2>&1; then
    echo "[WARN] ssh is not installed; skipping ${session}" >&2
    return
  fi
  if ! command -v tmux >/dev/null 2>&1; then
    echo "[WARN] tmux is not installed; skipping ${session}" >&2
    return
  fi

  tmux kill-session -t "${session}" >/dev/null 2>&1 || true
  tmux new-session -d -s "${session}" \
    "set -a; . '${env_file}'; set +a; '${RUNTIME_DIR}/start-remote-proxy-forward.sh'"
}

write_codex_config() {
  local codex_config="$HOME/.codex/config.toml"
  mkdir -p "$HOME/.codex"
  chmod 700 "$HOME/.codex"

  if [[ -f "${codex_config}" ]] && ! grep -Fq "Auto-generated by amd-node-setup" "${codex_config}"; then
    cp -p "${codex_config}" "${codex_config}.bak.$(date +%Y%m%d%H%M%S)"
  fi

  {
    echo "# Auto-generated by amd-node-setup. This file is container local."
    echo "# Codex uses a custom Chat Completions provider because the current AMD"
    echo "# Gateway Responses path rejects newer Codex metadata fields."
    printf 'model = "%s"\n' "${CODEX_MODEL}"
    printf 'model_provider = "%s"\n' "${CODEX_PROVIDER_ID}"
    printf 'model_reasoning_effort = "%s"\n' "${CODEX_REASONING_EFFORT}"
    echo
    printf '[model_providers.%s]\n' "${CODEX_PROVIDER_ID}"
    printf 'name = "%s"\n' "${CODEX_PROVIDER_NAME}"
    printf 'base_url = "%s"\n' "${CODEX_BASE_URL}"
    if [[ -n "${CODEX_PROVIDER_ENV_KEY}" ]]; then
      printf 'env_key = "%s"\n' "${CODEX_PROVIDER_ENV_KEY}"
    fi
    if [[ -n "${CODEX_PROVIDER_HEADER_ENV_KEY}" ]]; then
      printf 'env_http_headers = { "Ocp-Apim-Subscription-Key" = "%s" }\n' "${CODEX_PROVIDER_HEADER_ENV_KEY}"
    fi
    if [[ "${CODEX_PROVIDER_WIRE_API}" != "chat" ]]; then
      printf 'wire_api = "%s"\n' "${CODEX_PROVIDER_WIRE_API}"
    fi
  } > "${codex_config}"
  chmod 600 "${codex_config}"
}

write_wrappers() {
  local real_claude=""
  local real_codex=""

  real_claude="$(find_real_bin claude || true)"
  real_codex="$(find_real_bin codex || true)"

  mkdir -p "${RUNTIME_BIN_DIR}"
  chmod 700 "${RUNTIME_DIR}" "${RUNTIME_BIN_DIR}"

  if [[ -n "${real_claude}" ]]; then
    {
      echo "#!/usr/bin/env bash"
      echo "set -Eeuo pipefail"
      printf '. %q\n' "${RUNTIME_DIR}/claude-env.sh"
      printf 'real_claude=%q\n' "${real_claude}"
      echo 'for arg in "$@"; do'
      echo '  case "${arg}" in'
      echo '    -h|--help|-v|--version) exec "${real_claude}" "$@" ;;'
      echo '  esac'
      echo 'done'
      echo 'if [[ "${CLAUDE_ULTRACODE:-1}" == "1" ]]; then'
      echo '  exec "${real_claude}" --settings '"'"'{"ultracode":true}'"'"' "$@"'
      echo "fi"
      echo 'exec "${real_claude}" "$@"'
    } > "${RUNTIME_BIN_DIR}/claude"
    chmod 700 "${RUNTIME_BIN_DIR}/claude"
  else
    echo "[WARN] claude binary not found; wrapper not written" >&2
  fi

  if [[ -n "${real_codex}" ]]; then
    {
      echo "#!/usr/bin/env bash"
      echo "set -Eeuo pipefail"
      printf '. %q\n' "${RUNTIME_DIR}/codex-env.sh"
      printf 'real_codex=%q\n' "${real_codex}"
      echo 'exec "${real_codex}" "$@"'
    } > "${RUNTIME_BIN_DIR}/codex"
    chmod 700 "${RUNTIME_BIN_DIR}/codex"
  else
    echo "[WARN] codex binary not found; wrapper not written" >&2
  fi
}

case "${PROXY_BACKEND}" in
  local|remote)
    ;;
  *)
    fail "PROXY_BACKEND must be 'local' or 'remote'"
    ;;
esac

if [[ "${PROXY_BACKEND}" == "local" && -z "${LLM_GATEWAY_API_KEY}" ]]; then
  fail "LLM_GATEWAY_API_KEY is required when PROXY_BACKEND=local"
fi

mkdir -p "${RUNTIME_DIR}" "${RUNTIME_BIN_DIR}" "$HOME/.claude"
chmod 700 "${RUNTIME_DIR}" "${RUNTIME_BIN_DIR}" "$HOME/.claude"
umask 077

if [[ "${PROXY_BACKEND}" == "local" ]]; then
  {
    write_export AMD_LLM_API_KEY "${LLM_GATEWAY_API_KEY}"
    write_export AMD_LLM_BASE_URL "${LLM_GATEWAY_BASE_URL}"
    write_export AMD_USER_NTID "${AMD_USER_NTID}"
    write_export PROXY_HOST "${PROXY_HOST}"
    write_export PROXY_PORT "${CLAUDE_PROXY_PORT}"
    write_export PROXY_MODE "claude"
    write_export CLAUDE_DEFAULT_MODEL "${CLAUDE_MODEL}"
    write_export AMD_PROXY_MODELS "${CLAUDE_MODEL}"
  } > "${RUNTIME_DIR}/amdproxy-claude.env"

  {
    write_export AMD_LLM_API_KEY "${LLM_GATEWAY_API_KEY}"
    write_export AMD_LLM_BASE_URL "${LLM_GATEWAY_BASE_URL}"
    write_export AMD_USER_NTID "${AMD_USER_NTID}"
    write_export PROXY_HOST "${PROXY_HOST}"
    write_export PROXY_PORT "${CODEX_PROXY_PORT}"
    write_export PROXY_MODE "openai"
    write_export OPENAI_UPSTREAM_BASE_URL "${LLM_GATEWAY_OPENAI_BASE_URL}"
    write_export CODEX_DEFAULT_MODEL "${CODEX_MODEL}"
    write_export CODEX_REASONING_EFFORT "${CODEX_REASONING_EFFORT}"
    write_export AMD_PROXY_MODELS "${CODEX_MODEL}"
  } > "${RUNTIME_DIR}/amdproxy-codex.env"
else
  write_ssh_forward_runner

  {
    write_export PROXY_HOST "${PROXY_HOST}"
    write_export LOCAL_PROXY_PORT "${CLAUDE_PROXY_PORT}"
    write_export REMOTE_PROXY_HOST "${REMOTE_CLAUDE_PROXY_HOST}"
    write_export REMOTE_PROXY_PORT "${REMOTE_CLAUDE_PROXY_PORT}"
    write_export REMOTE_PROXY_SSH_TARGET "${REMOTE_PROXY_SSH_TARGET}"
    write_export REMOTE_PROXY_SSH_OPTS "${REMOTE_PROXY_SSH_OPTS}"
  } > "${RUNTIME_DIR}/remote-proxy-claude.env"

  {
    write_export PROXY_HOST "${PROXY_HOST}"
    write_export LOCAL_PROXY_PORT "${CODEX_PROXY_PORT}"
    write_export REMOTE_PROXY_HOST "${REMOTE_CODEX_PROXY_HOST}"
    write_export REMOTE_PROXY_PORT "${REMOTE_CODEX_PROXY_PORT}"
    write_export REMOTE_PROXY_SSH_TARGET "${REMOTE_PROXY_SSH_TARGET}"
    write_export REMOTE_PROXY_SSH_OPTS "${REMOTE_PROXY_SSH_OPTS}"
  } > "${RUNTIME_DIR}/remote-proxy-codex.env"
fi

{
  write_export ANTHROPIC_BASE_URL "${CLAUDE_BASE_URL}"
  # Only set ANTHROPIC_AUTH_TOKEN. Setting ANTHROPIC_API_KEY as well makes
  # Claude Code warn that auth "may not work as expected"; the proxy injects
  # the real gateway key (Ocp-Apim-Subscription-Key) regardless of this value.
  write_export ANTHROPIC_AUTH_TOKEN "not-used"
  write_export ANTHROPIC_MODEL "${CLAUDE_MODEL}"
  case "${CLAUDE_MODEL}" in
    *fable*)
      write_export ANTHROPIC_DEFAULT_FABLE_MODEL "${CLAUDE_MODEL}"
      ;;
    *sonnet*)
      write_export ANTHROPIC_DEFAULT_SONNET_MODEL "${CLAUDE_MODEL}"
      ;;
    *haiku*)
      write_export ANTHROPIC_DEFAULT_HAIKU_MODEL "${CLAUDE_MODEL}"
      ;;
    *)
      write_export ANTHROPIC_DEFAULT_OPUS_MODEL "${CLAUDE_MODEL}"
      ;;
  esac
  write_export CLAUDE_CODE_EFFORT_LEVEL "${CLAUDE_EFFORT}"
  write_export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY "1"
  write_export CLAUDE_ULTRACODE "${CLAUDE_ULTRACODE}"
} > "${RUNTIME_DIR}/claude-env.sh"

{
  write_export OPENAI_API_KEY "${LLM_GATEWAY_API_KEY:-not-used}"
  if [[ -n "${LLM_GATEWAY_API_KEY}" ]]; then
    write_export LLM_GATEWAY_KEY "${LLM_GATEWAY_API_KEY}"
  fi
  write_export OPENAI_BASE_URL "${CODEX_BASE_URL}"
  write_export CODEX_MODEL "${CODEX_MODEL}"
  write_export CODEX_REASONING_EFFORT "${CODEX_REASONING_EFFORT}"
  write_export CODEX_REASONING_LABEL "${CODEX_REASONING_LABEL}"
  write_export CODEX_PROVIDER_ID "${CODEX_PROVIDER_ID}"
  write_export CODEX_PROVIDER_WIRE_API "${CODEX_PROVIDER_WIRE_API}"
} > "${RUNTIME_DIR}/codex-env.sh"

{
  echo "# Auto-generated by amd-node-setup. This file is node/container local."
  echo "export PATH=\"${RUNTIME_BIN_DIR}:\$HOME/.local/bin:\$PATH\""
  echo "[ -f \"${RUNTIME_DIR}/claude-env.sh\" ] && . \"${RUNTIME_DIR}/claude-env.sh\""
  echo "[ -f \"${RUNTIME_DIR}/codex-env.sh\" ] && . \"${RUNTIME_DIR}/codex-env.sh\""
} > "${RUNTIME_DIR}/env.sh"

chmod 600 "${RUNTIME_DIR}"/*.env "${RUNTIME_DIR}/claude-env.sh" "${RUNTIME_DIR}/codex-env.sh" "${RUNTIME_DIR}/env.sh"
if [[ -f "${RUNTIME_DIR}/start-remote-proxy-forward.sh" ]]; then
  chmod 700 "${RUNTIME_DIR}/start-remote-proxy-forward.sh"
fi
write_codex_config
write_wrappers

append_once \
  "$HOME/.bashrc" \
  "${RUNTIME_DIR}/env.sh" \
  "# amd-node-setup agent/proxy env
[ -f \"${RUNTIME_DIR}/env.sh\" ] && . \"${RUNTIME_DIR}/env.sh\""

if [[ "${PROXY_BACKEND}" == "local" ]]; then
  start_tmux_session amdproxy-claude "${RUNTIME_DIR}/amdproxy-claude.env"
  start_tmux_session amdproxy-codex "${RUNTIME_DIR}/amdproxy-codex.env"
else
  start_ssh_forward_session amdproxy-claude-forward "${RUNTIME_DIR}/remote-proxy-claude.env"
  start_ssh_forward_session amdproxy-codex-forward "${RUNTIME_DIR}/remote-proxy-codex.env"
fi

codex_health_url="${CODEX_BASE_URL%/}"
if [[ "${codex_health_url}" == */v1 ]]; then
  codex_health_url="${codex_health_url%/v1}"
fi

if [[ "${PROXY_BACKEND}" == "local" ]]; then
  proxy_session_summary="  amdproxy-claude -> ${CLAUDE_BASE_URL}"$'\n'"  amdproxy-codex  -> ${CODEX_BASE_URL}"
elif [[ -n "${REMOTE_PROXY_SSH_TARGET}" && "${REMOTE_PROXY_START_SSH_TUNNELS}" == "1" ]]; then
  proxy_session_summary="  amdproxy-claude-forward -> ${REMOTE_PROXY_SSH_TARGET}:${REMOTE_CLAUDE_PROXY_HOST}:${REMOTE_CLAUDE_PROXY_PORT}"$'\n'"  amdproxy-codex-forward  -> ${REMOTE_PROXY_SSH_TARGET}:${REMOTE_CODEX_PROXY_HOST}:${REMOTE_CODEX_PROXY_PORT}"
else
  proxy_session_summary="  no tmux forwards started; using direct URLs or pre-existing forwards"
fi

cat <<SUMMARY
Agent runtime configured.

Local env directory:
  ${RUNTIME_DIR}

Proxy backend:
  ${PROXY_BACKEND}

Agent endpoints:
  Claude Code -> ${CLAUDE_BASE_URL}  model=${CLAUDE_MODEL}  effort=ultracode/${CLAUDE_EFFORT}
  Codex       -> ${CODEX_BASE_URL}  model=${CODEX_MODEL}  effort=${CODEX_REASONING_LABEL}/${CODEX_REASONING_EFFORT}

Proxy sessions:
${proxy_session_summary}

Default commands after opening a new shell:
  claude
  codex

Health checks:
  curl ${CLAUDE_BASE_URL%/}/health
  curl ${codex_health_url}/health

GitHub auth remains manual:
  gh auth login
SUMMARY
