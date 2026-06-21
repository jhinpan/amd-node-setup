# AMD node runtime toolkit

Public-repo draft for setting up AMD ROCm model-serving/dev nodes.

This repository is meant for the workflow where a human gives a Cursor agent a target container name, and the agent prepares the rest:

1. detect whether the node is MI30x or MI35x class
2. choose the latest stable `rocm720` `rocm/sgl-dev` Docker image for that GPU family
3. detect likely model-cache and workspace mount paths on the node
4. create a ROCm dev container with the expected GPU/Docker flags
5. install `tmux`, `gh`, Claude Code, Codex CLI, and common tools inside the container
6. configure the proxy path for Claude Code/Codex experiments

No real keys, tokens, Anyscale sessions, websocket URLs, or node-private paths belong in this public repo.

## Why a Public Repo

Use this as a normal public GitHub repo, not a large gist.

The setup now has multiple scripts, proxy implementations, systemd templates, and docs. A repo gives us history, reviews, issues, and normal clone/update behavior. Gists are still useful only for tiny one-liner bootstrap snippets.

## Layout

```text
scripts/
  setup-dev-env.sh                 # installs tmux, gh, Node/npm, uv, Codex, Claude Code
docker/
  start-rocm-dev-container.sh      # creates the generic ROCm dev container
  litellm-config.example.yaml      # optional Anthropic/OpenAI bridge config
proxy/
  amd_proxy.py                     # Anthropic Messages API -> AMD LLM gateway
  shared-proxy.js                  # portable Anyscale sshproxy wrapper
  anyscale-workspace-config.example.json
systemd/
  amdproxy.service                 # optional service template for amd_proxy.py
  amdproxy-reverse-tunnel.service  # optional reverse tunnel template
docs/
  review-questions.md
```

## Current CLI Requirements

Checked on 2026-06-21:

- `@openai/codex@latest` npm metadata says Node `>=16`.
- `@anthropic-ai/claude-code@latest` npm metadata says Node `>=18.0.0`.
- Claude Code is stricter, so the bootstrap installs Node 20 LTS by default.

References:

- OpenAI Codex CLI install docs: <https://developers.openai.com/codex/cli>
- OpenAI Codex repo install docs: <https://github.com/openai/codex>
- Anthropic Claude Code setup docs: <https://code.claude.com/docs/en/setup>

## Bootstrap Tools Inside a Container

Run this inside a fresh ROCm dev container:

```bash
bash scripts/setup-dev-env.sh
```

The script installs:

- `tmux`
- `git`, `curl`, `wget`, `jq`, `ripgrep`, `rsync`, `openssh-client`, `vim`, `htop`
- `python3`, `pip`, `venv`, `uv`
- Node.js/npm, default `NODE_MAJOR=20`
- GitHub CLI `gh`
- OpenAI Codex CLI: `npm install -g @openai/codex@latest`
- Claude Code: `npm install -g @anthropic-ai/claude-code@latest`

Claude Code docs explicitly recommend upgrading npm installs with:

```bash
npm install -g @anthropic-ai/claude-code@latest
```

The bootstrap uses the same pattern for both Claude Code and Codex, so each run updates them to the current npm `latest` release. It does not run `gh auth login`; authentication is manual:

```bash
gh auth login
gh auth status
```

Useful switches:

```bash
NODE_MAJOR=20 bash scripts/setup-dev-env.sh
INSTALL_CODEX=0 INSTALL_CLAUDE=0 bash scripts/setup-dev-env.sh
INSTALL_GH=0 bash scripts/setup-dev-env.sh
```

## Create a ROCm Dev Container

From this repo on the host:

```bash
CONTAINER_NAME=my-amd-test bash docker/start-rocm-dev-container.sh
```

Preview detection and the generated Docker command without creating a container:

```bash
DRY_RUN=1 CONTAINER_NAME=my-amd-test bash docker/start-rocm-dev-container.sh
```

The script will:

- detect GPU family from `rocm-smi`, `rocminfo`, or `lspci`
- use `mi35x` for MI350/MI355/gfx950-class nodes
- use `mi30x` for MI300/MI300X/MI325/gfx942-class nodes
- query Docker Hub for the latest stable tag matching `v*.rocm720-{family}-YYYYMMDD`
- fall back to the 2026-06-20 tags if Docker Hub is unavailable
- detect likely model mounts such as `/mnt/dcgpuval/huggingface`, `/data/huggingface`, `/data/models`, `/models`, and `~/.cache/huggingface`
- detect/create a workspace mount
- run `scripts/setup-dev-env.sh` inside the container

Example images used as fallbacks:

```bash
rocm/sgl-dev:v0.5.13.post1-rocm720-mi35x-20260620
rocm/sgl-dev:v0.5.13.post1-rocm720-mi30x-20260620
```

The container always starts with:

```bash
--network=host
--ipc=host
--privileged
--shm-size 128G
--cap-add=CAP_SYS_ADMIN
--cap-add=SYS_PTRACE
--device=/dev/kfd
--device=/dev/dri
--group-add video
--security-opt seccomp=unconfined
--security-opt apparmor=unconfined
```

It also sets:

```bash
SGLANG_USE_AITER=1
SGLANG_ROCM_FUSED_DECODE_MLA=0
HF_HOME=/sgl-workspace/models
```

This is intentional. `SGLANG_USE_AITER=1` is a default ROCm/SGLang experiment setting in this repo. Override it only when testing a path that should avoid AITER:

```bash
SGLANG_USE_AITER=0 CONTAINER_NAME=my-no-aiter-test bash docker/start-rocm-dev-container.sh
```

Attach to the container:

```bash
docker exec -it my-amd-test tmux new -A -s agent
```

Then the agent can inspect `/sgl-workspace/models`, choose a model, and launch SGLang with the model-specific flags required for that test.

## Override Detection

The agent can override anything explicitly:

```bash
CONTAINER_NAME=my-test \
GPU_FAMILY=mi30x \
IMAGE=rocm/sgl-dev:v0.5.13.post1-rocm720-mi30x-20260620 \
HOST_MODEL_CACHE=/mnt/dcgpuval/huggingface \
HOST_WORKSPACE=/mnt/dcgpuval/sgl-workspace \
bash docker/start-rocm-dev-container.sh
```

## AMDproxy for Claude Code

For AMD corporate gateway:

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install requests

export AMD_LLM_API_KEY=REPLACE_WITH_SUBSCRIPTION_KEY
export PROXY_HOST=127.0.0.1
export PROXY_PORT=8082
python3 proxy/amd_proxy.py
```

Point Claude Code at it:

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:8082
export ANTHROPIC_AUTH_TOKEN=not-used
export ANTHROPIC_API_KEY=not-used
export DISABLE_PROMPT_CACHING=1
claude
```

Health checks:

```bash
curl http://127.0.0.1:8082/health
curl http://127.0.0.1:8082/v1/models
```

## Optional LiteLLM Bridge

If the test uses a local SGLang OpenAI-compatible server and Claude Code as the client:

```bash
docker run -d \
  --name litellm-proxy \
  --network host \
  -v "$PWD/docker/litellm-config.example.yaml:/app/config.yaml" \
  -e LITELLM_MASTER_KEY="LOCAL_PROXY_TOKEN" \
  ghcr.io/berriai/litellm:main-latest \
  --config /app/config.yaml \
  --port 4000
```

Then:

```bash
export ANTHROPIC_BASE_URL=http://127.0.0.1:4000
export ANTHROPIC_AUTH_TOKEN=LOCAL_PROXY_TOKEN
export ANTHROPIC_API_KEY=LOCAL_PROXY_TOKEN
export DISABLE_PROMPT_CACHING=1
claude
```

## Optional Reverse Tunnel

If AMDproxy runs on one machine but should appear on another control node, adapt:

```text
systemd/amdproxy-reverse-tunnel.service
```

The current template maps local `127.0.0.1:8082` to control-node `127.0.0.1:8882` and `127.0.0.1:8883`.

## Agent Prompt Pattern

Example human instruction to Cursor:

```text
Use this repo to create a ROCm dev container named qwen-test.
Detect whether this node is MI30x or MI35x, choose the latest stable rocm720 rocm/sgl-dev image,
mount the local model cache and workspace, install tmux/gh/Claude Code/Codex inside the container,
then attach a tmux session and prepare the proxy settings for Claude Code.
Do not commit secrets.
```
