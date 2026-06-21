# amd-node-setup

Public repo for setting up AMD ROCm dev/model-serving nodes for agent work.

The intended workflow is deliberately small. A human gives a Cursor agent exactly two operational inputs:

1. Docker container name
2. Application API key from the LLM API Gateway

The agent then detects the node, creates the ROCm dev container, installs the agent CLIs, configures the AMD gateway proxies, and leaves the container ready for Claude Code, Codex, and SGLang model-serving tests.

No real API keys, tokens, node-private mount paths, reverse SSH tunnel details, or account-specific gateway internals belong in this public repo.

## What This Sets Up

- A ROCm/SGLang dev container selected for MI30x or MI35x class GPUs.
- Docker runtime flags that match the current AMD node workflow, including `--privileged` and `--shm-size 128G`.
- Tooling inside the container: `tmux`, `gh`, Node/npm, Claude Code, Codex CLI, `uv`, Python helpers, and common shell tools.
- Two container-local `tmux` proxy sessions:
  - `amdproxy-claude` on `127.0.0.1:8082` for Claude Code.
  - `amdproxy-codex` on `127.0.0.1:8083` for Codex/OpenAI-compatible traffic.
- Default agent model settings:
  - Claude Code: Opus 4.8 through the AMD gateway, with ultracode enabled by the generated wrapper and `xhigh` sent as the model effort.
  - Codex: GPT 5.5 with Codex `model_reasoning_effort = "xhigh"`, used here as the current Codex config equivalent of the requested ultrahigh setting.

This repo does not create a reverse SSH tunnel and does not launch a model-specific SGLang server by default. The agent should inspect `/sgl-workspace/models` and choose model-specific SGLang flags only after the container exists.

## Layout

```text
scripts/
  setup-dev-env.sh             # installs tmux, gh, Node/npm, uv, Codex, Claude Code
  setup-agent-runtime.sh       # writes env/config files and starts both proxy tmux sessions
docker/
  start-rocm-dev-container.sh  # creates the ROCm dev container
proxy/
  amd_proxy.py                 # Claude translator mode and OpenAI-compatible passthrough mode
systemd/
  amdproxy.service             # optional non-container service template
docs/
  cursor-agent-workflow.md
  review-questions.md
```

## Current CLI Requirements

Checked on 2026-06-21:

- `@openai/codex@latest` npm metadata reports Node `>=16`.
- `@anthropic-ai/claude-code@latest` npm metadata reports Node `>=18.0.0`.
- This repo installs Node 20 LTS by default because Claude Code is stricter.

References:

- OpenAI Codex config basics: <https://developers.openai.com/codex/config-basic>
- OpenAI Codex advanced config: <https://developers.openai.com/codex/config-advanced>
- Anthropic Claude Code setup: <https://code.claude.com/docs/en/setup>
- Anthropic Claude Code model config: <https://code.claude.com/docs/en/model-config>

The bootstrap updates Claude Code and Codex on every run:

```bash
npm install -g @openai/codex@latest
npm install -g @anthropic-ai/claude-code@latest
```

GitHub CLI is installed, but authentication is intentionally manual:

```bash
gh auth login
gh auth status
```

## Create a ROCm Dev Container

From this repo on the host, provide the two required inputs:

```bash
CONTAINER_NAME=my-amd-test \
LLM_GATEWAY_API_KEY=REPLACE_WITH_APPLICATION_KEY \
bash docker/start-rocm-dev-container.sh
```

Preview detection and the generated Docker command without creating the container:

```bash
DRY_RUN=1 \
CONTAINER_NAME=my-amd-test \
LLM_GATEWAY_API_KEY=REPLACE_WITH_APPLICATION_KEY \
bash docker/start-rocm-dev-container.sh
```

The dry-run output masks the key.

To keep the key out of shell history:

```bash
read -rsp "LLM Gateway application key: " LLM_GATEWAY_API_KEY
echo
export LLM_GATEWAY_API_KEY
CONTAINER_NAME=my-amd-test bash docker/start-rocm-dev-container.sh
```

The script will:

- detect GPU family from `rocm-smi`, `rocminfo`, or `lspci`
- use `mi35x` for MI350/MI355/gfx950-class nodes
- use `mi30x` for MI300/MI300X/MI325/gfx942-class nodes
- query Docker Hub for the latest stable tag matching `v*.rocm720-{family}-YYYYMMDD`
- fall back to the 2026-06-20 images if Docker Hub is unavailable
- detect likely model mounts such as `/mnt/dcgpuval/huggingface`, `/data/huggingface`, `/data/models`, `/models`, and `~/.cache/huggingface`
- detect/create a workspace mount
- run `scripts/setup-dev-env.sh` inside the container
- run `scripts/setup-agent-runtime.sh` inside the container
- start `amdproxy-claude` and `amdproxy-codex` in `tmux`

Fallback image examples:

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

`SGLANG_USE_AITER=1` is intentional and visible in the script output. Override it only when the test specifically needs to avoid AITER:

```bash
SGLANG_USE_AITER=0 \
CONTAINER_NAME=my-no-aiter-test \
LLM_GATEWAY_API_KEY=REPLACE_WITH_APPLICATION_KEY \
bash docker/start-rocm-dev-container.sh
```

Attach to the container:

```bash
docker exec -it my-amd-test tmux new -A -s agent
```

## Runtime Files Inside the Container

`scripts/setup-agent-runtime.sh` writes container-local files under `~/.amd-node-setup/`:

```text
amdproxy-claude.env    # Claude proxy settings for port 8082
amdproxy-codex.env     # Codex/OpenAI-compatible proxy settings for port 8083
claude-env.sh          # Claude Code env
codex-env.sh           # Codex env
env.sh                 # PATH and shared shell env
bin/claude             # wrapper around the npm Claude Code binary
bin/codex              # wrapper around the npm Codex binary
```

It also writes `~/.codex/config.toml` with:

```toml
model = "gpt-5.5"
model_reasoning_effort = "xhigh"
openai_base_url = "http://127.0.0.1:8083/v1"
```

If `~/.codex/config.toml` already exists and was not generated by this repo, it is backed up first.

## Proxy Sessions

Claude Code proxy:

```bash
tmux attach -t amdproxy-claude
curl http://127.0.0.1:8082/health
curl http://127.0.0.1:8082/v1/models
```

The generated `claude` wrapper sources `~/.amd-node-setup/claude-env.sh` and runs Claude Code with ultracode enabled:

```bash
claude
```

Codex proxy:

```bash
tmux attach -t amdproxy-codex
curl http://127.0.0.1:8083/health
curl http://127.0.0.1:8083/v1/models
```

The generated `codex` wrapper sources `~/.amd-node-setup/codex-env.sh`:

```bash
codex
```

The Codex proxy defaults to forwarding OpenAI-compatible requests to:

```text
https://llm-api.amd.com/v1
```

If the LLM API Gateway exposes GPT/Codex-compatible models at a different base URL on a specific node/account, pass it while creating the container:

```bash
LLM_GATEWAY_OPENAI_BASE_URL=https://llm-api.amd.com/REPLACE_WITH_OPENAI_COMPATIBLE_BASE \
CONTAINER_NAME=my-amd-test \
LLM_GATEWAY_API_KEY=REPLACE_WITH_APPLICATION_KEY \
bash docker/start-rocm-dev-container.sh
```

## Override Detection

The agent can override detection explicitly when needed:

```bash
CONTAINER_NAME=my-test \
LLM_GATEWAY_API_KEY=REPLACE_WITH_APPLICATION_KEY \
GPU_FAMILY=mi30x \
IMAGE=rocm/sgl-dev:v0.5.13.post1-rocm720-mi30x-20260620 \
HOST_MODEL_CACHE=/mnt/dcgpuval/huggingface \
HOST_WORKSPACE=/mnt/dcgpuval/sgl-workspace \
bash docker/start-rocm-dev-container.sh
```

## Agent Prompt Pattern

Example instruction to Cursor:

```text
Use the amd-node-setup repo to create a ROCm dev container named qwen-test.
The LLM Gateway application API key is: <paste key>.
Detect whether this node is MI30x or MI35x, choose the latest stable rocm720 rocm/sgl-dev image,
mount the local model cache and workspace, install tmux/gh/Claude Code/Codex inside the container,
configure Claude Code through port 8082 and Codex through port 8083, start both AMD proxy tmux sessions,
then attach a tmux session.
Do not commit secrets.
```
