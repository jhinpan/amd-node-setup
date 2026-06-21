#!/usr/bin/env bash
# Bootstrap a fresh Ubuntu/Debian ROCm dev container or node.
#
# Installs:
#   - common shell/dev tools: tmux, git, curl, wget, jq, ripgrep, rsync, vim, htop
#   - Python helpers: python3, pip, venv, uv
#   - Node.js + npm, defaulting to Node 20 LTS
#   - GitHub CLI: gh
#   - agent CLIs: codex and claude
#
# Usage:
#   curl -fsSL RAW_URL/scripts/setup-dev-env.sh | bash
#   NODE_MAJOR=20 INSTALL_CODEX=0 bash scripts/setup-dev-env.sh

set -Eeuo pipefail

NODE_MAJOR="${NODE_MAJOR:-20}"
INSTALL_CODEX="${INSTALL_CODEX:-1}"
INSTALL_CLAUDE="${INSTALL_CLAUDE:-1}"
INSTALL_GH="${INSTALL_GH:-1}"
INSTALL_UV="${INSTALL_UV:-1}"
DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
export DEBIAN_FRONTEND

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  NC=$'\033[0m'
else
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  NC=""
fi

info() { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"; }
success() { printf '%s[OK]%s %s\n' "$GREEN" "$NC" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*"; }
fail() { printf '%s[ERROR]%s %s\n' "$RED" "$NC" "$*" >&2; exit 1; }

if [[ "$(uname -s)" != "Linux" ]]; then
  fail "This bootstrap is intended for Linux containers/nodes."
fi

if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=()
elif command -v sudo >/dev/null 2>&1; then
  SUDO=(sudo)
else
  fail "Run as root or install sudo first."
fi

have() { command -v "$1" >/dev/null 2>&1; }

apt_install() {
  "${SUDO[@]}" apt-get install -y -qq "$@"
}

node_major() {
  if ! have node; then
    echo 0
    return
  fi
  node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || echo 0
}

install_base_packages() {
  info "Updating apt metadata"
  "${SUDO[@]}" apt-get update -qq

  info "Installing base packages"
  apt_install \
    ca-certificates curl wget gnupg lsb-release apt-transport-https \
    git openssh-client rsync tmux jq ripgrep vim htop less file \
    python3 python3-pip python3-venv python3-requests build-essential
  success "Base packages installed"
}

install_node() {
  local current_major
  current_major="$(node_major)"
  if [[ "$current_major" -ge "$NODE_MAJOR" ]] && have npm; then
    success "Node.js already available: $(node -v), npm $(npm -v)"
    return
  fi

  info "Installing Node.js ${NODE_MAJOR}.x from NodeSource"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | "${SUDO[@]}" bash -
  apt_install nodejs
  success "Node.js installed: $(node -v), npm $(npm -v)"
}

install_uv() {
  if [[ "$INSTALL_UV" != "1" ]]; then
    warn "Skipping uv because INSTALL_UV=${INSTALL_UV}"
    return
  fi

  if have uv; then
    success "uv already available: $(uv --version)"
    return
  fi

  info "Installing uv"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
  if [[ -f "$HOME/.bashrc" ]] && ! grep -Fq 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.bashrc"; then
    printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$HOME/.bashrc"
  fi
  success "uv installed: $(uv --version)"
}

install_gh() {
  if [[ "$INSTALL_GH" != "1" ]]; then
    warn "Skipping gh because INSTALL_GH=${INSTALL_GH}"
    return
  fi

  if have gh; then
    success "gh already available: $(gh --version | head -n 1)"
    return
  fi

  info "Installing GitHub CLI"
  "${SUDO[@]}" mkdir -p -m 755 /etc/apt/keyrings
  local keyring
  keyring="$(mktemp)"
  wget -qO "$keyring" https://cli.github.com/packages/githubcli-archive-keyring.gpg
  cat "$keyring" | "${SUDO[@]}" tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  rm -f "$keyring"
  "${SUDO[@]}" chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  "${SUDO[@]}" mkdir -p -m 755 /etc/apt/sources.list.d
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | "${SUDO[@]}" tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  "${SUDO[@]}" apt-get update -qq
  apt_install gh
  success "gh installed: $(gh --version | head -n 1)"
}

install_agent_clis() {
  if [[ "$INSTALL_CODEX" == "1" ]]; then
    info "Installing/updating OpenAI Codex CLI to npm latest"
    npm install -g @openai/codex@latest
    success "codex available: $(codex --version 2>/dev/null || echo installed)"
  else
    warn "Skipping codex because INSTALL_CODEX=${INSTALL_CODEX}"
  fi

  if [[ "$INSTALL_CLAUDE" == "1" ]]; then
    info "Installing/updating Claude Code CLI to npm latest"
    npm install -g @anthropic-ai/claude-code@latest
    success "claude available: $(claude --version 2>/dev/null || echo installed)"
  else
    warn "Skipping claude because INSTALL_CLAUDE=${INSTALL_CLAUDE}"
  fi
}

print_summary() {
  cat <<SUMMARY

Setup complete.

Tool versions:
  tmux   : $(tmux -V 2>/dev/null || echo missing)
  git    : $(git --version 2>/dev/null || echo missing)
  rg     : $(rg --version 2>/dev/null | head -n 1 || echo missing)
  jq     : $(jq --version 2>/dev/null || echo missing)
  node   : $(node -v 2>/dev/null || echo missing)
  npm    : $(npm -v 2>/dev/null || echo missing)
  uv     : $(uv --version 2>/dev/null || echo missing)
  gh     : $(gh --version 2>/dev/null | head -n 1 || echo missing)
  codex  : $(codex --version 2>/dev/null || echo missing)
  claude : $(claude --version 2>/dev/null || echo missing)

Next steps:
  - Run 'source ~/.bashrc' or open a new shell if uv was newly installed.
  - GitHub auth is intentionally manual; run 'gh auth login' if this node needs it.
  - For Claude Code through AMDproxy, set ANTHROPIC_BASE_URL and ANTHROPIC_AUTH_TOKEN/API_KEY.
SUMMARY
}

install_base_packages
install_node
install_uv
install_gh
install_agent_clis
print_summary
