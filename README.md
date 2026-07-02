# amd-node-setup

Public repo for setting up AMD ROCm dev/model-serving nodes for agent work.

The intended workflow is deliberately small. A human gives a Cursor agent the mode-specific operational inputs:

1. Docker container name
2. Either an LLM Gateway application key for a conductor/local-proxy node, or a paired n0809 proxy route for a TensorWave/remote-proxy node

The agent then detects the node class and GPU family, creates the ROCm dev container, installs the agent CLIs, configures Claude Code and Codex through the right AMD proxy path, and leaves the container ready for Claude Code, Codex, and SGLang model-serving tests.

No real API keys, tokens, node-private mount paths, reverse SSH tunnel details, or account-specific gateway internals belong in this public repo.

## Bare-Metal Node Flow

This flow assumes the agent is already logged into the target bare-metal AMD node, usually an MI300/MI300X/MI325 or MI350/MI355 machine. Docker should already be installed and usable by the agent on the host. The repo does not provision the node itself; remote proxy mode creates only container-local SSH forwards when requested.

![amd-node-setup bare-metal MI node flow](docs/setup-flow.svg)

## Node Classes

This repo separates AMD hosts into two operational classes because the LLM proxy path is different:

- `conductor`: n0809/0809-style AMD-internal nodes. These can hold the AMD LLM Gateway application key and run local key-backed AMD proxy sessions.
- `tensorwave`: TensorWave GPU nodes such as G45, G46, and G05. These should run the ROCm/SGLang workload container, but normally use Claude Code and Codex proxies that are already running on a paired conductor node such as n0809.

`docker/start-rocm-dev-container.sh` detects this as `AMD_NODE_CLASS=auto`. Set `AMD_NODE_CLASS=conductor` or `AMD_NODE_CLASS=tensorwave` when the hostname is ambiguous.

## TensorWave G45/G46/G05 With n0809 Proxy Flow

For TensorWave nodes such as G45, G46, and G05, the ROCm/SGLang container runs on the target node while Claude Code and Codex use AMDproxy instances that live on the paired n0809 conductor node. This is useful when only n0809 can deploy the company-facing proxy.

In this mode, the TensorWave node does not need the LLM Gateway application key. The container writes the same Claude/Codex local endpoint config as before, but starts two SSH local forwards:

```text
g45 container Claude Code -> 127.0.0.1:8082 -> ssh -L -> n0809 127.0.0.1:8082
g45 container Codex       -> 127.0.0.1:8083 -> ssh -L -> n0809 127.0.0.1:8083
```

The n0809 node must already have working proxy listeners:

```bash
curl http://127.0.0.1:8082/health
curl http://127.0.0.1:8083/health
```

Then start the TensorWave container with remote proxy mode:

```bash
CONTAINER_NAME=g45-sglang-agent \
PROXY_BACKEND=remote \
REMOTE_PROXY_SSH_TARGET=n0809 \
FORWARD_SSH_AGENT=1 \
bash docker/start-rocm-dev-container.sh
```

If SSH agent forwarding is not available inside Docker, either set `MOUNT_HOST_SSH=1` to mount host SSH config/keys read-only, or pre-create the forwards outside the container and use `REMOTE_PROXY_START_SSH_TUNNELS=0`.

On conductor nodes such as n0809/0809, use `PROXY_BACKEND=local` with `LLM_GATEWAY_API_KEY`. If a TensorWave node must reach those local proxy ports, expose them through an operator-managed reverse tunnel or by starting `PROXY_BACKEND=remote` from the TensorWave side.

## Step Review

| Step | What the agent does | Decision conditions | Installs or writes | Expected result |
| --- | --- | --- | --- | --- |
| 1. Start on node | Work directly on the target bare-metal MI node. | The node should already have shell access, Docker installed, and Docker permission. | Nothing yet. | Agent is operating on the same node that will host the ROCm dev container. |
| 2. Collect inputs | Require `CONTAINER_NAME`. In default `PROXY_BACKEND=local`, also require `LLM_GATEWAY_API_KEY`. In `PROXY_BACKEND=remote`, require a reachable proxy URL or `REMOTE_PROXY_SSH_TARGET`. | If required values are missing, `docker/start-rocm-dev-container.sh` exits before Docker work. | Nothing committed; local mode passes the key through env; TensorWave remote mode can avoid putting the key on the GPU node. | Human provides either conductor gateway credentials or the paired n0809 proxy route. |
| 3. Detect GPU family | Read `rocm-smi`, `rocminfo`, and `lspci` output when available. | MI300/MI300X/MI325/gfx942 -> `mi30x`; MI350/MI355/gfx950 -> `mi35x`; unknown -> warn and default to `mi35x`; override with `GPU_FAMILY`. | Nothing installed. | Correct ROCm/SGLang Docker image family is selected. |
| 4. Select image | Query Docker Hub for the newest stable `v*.rocm720-{family}-YYYYMMDD` tag. | If Docker Hub query fails or no matching tag is found, use the 2026-06-20 fallback image for the detected family. | Nothing installed. | Container uses latest stable `rocm720` image for MI30x or MI35x. |
| 5. Detect mounts | Search common model-cache and workspace locations and verify they contain model artifacts. | Model cache candidates include `/mnt/dcgpuval/huggingface`, `/mnt/dcgpuval/models`, `/mnt/dcgpuval`, `/data/huggingface`, `/data/models`, `/data`, `/models`, `/mnt/models`, `/scratch`, `/scratch/huggingface`, `/scratch/models`, `~/.cache/huggingface`; override with `HOST_MODEL_CACHE`. A candidate is selected only when it contains model directories with files such as `config.json`, `*.safetensors`, `*.bin`, `*.gguf`, or `model.safetensors.index.json`. Workspace prefers `/mnt/dcgpuval/sgl-workspace`, `/workspace`, `~/sgl-workspace`, then `/tmp/sgl-workspace`; override with `HOST_WORKSPACE`. | Creates the workspace directory unless `DRY_RUN=1`. | Existing node-local model stores, such as GLM, Kimi, DeepSeek, or Qwen under `/scratch`, are mounted at `/sgl-workspace/models` when found. |
| 6. Create container | Run Docker with host networking and ROCm device access. | Always uses `--network=host`, `--ipc=host`, `--privileged`, `--shm-size 128G`, `/dev/kfd`, `/dev/dri`, `CAP_SYS_ADMIN`, `SYS_PTRACE`, unconfined seccomp/apparmor. | Sets `SGLANG_USE_AITER=1`, `SGLANG_ROCM_FUSED_DECODE_MLA=0`, `HF_HOME=/sgl-workspace/models`, repo mount at `/opt/amd-node-setup`. | Detached ROCm dev container starts and keeps running. |
| 7. Install base tools | Run `scripts/setup-dev-env.sh` inside the container. | Debian/Ubuntu-style container expected. Node defaults to 20 LTS; `INSTALL_*` flags can skip selected tools. | Installs apt packages: `tmux`, `git`, `curl`, `wget`, `jq`, `ripgrep`, `rsync`, `openssh-client`, `vim`, `htop`, `python3`, `pip`, `venv`, `python3-requests`, build tools, Node/npm, `uv`, and `gh`. | Container has shell/dev tooling and GitHub CLI; `gh auth login` remains manual. |
| 8. Install agent CLIs | Prefer native installers for Codex and Claude Code. | Codex native install runs with `CODEX_NON_INTERACTIVE=1`; Claude native install uses `CLAUDE_NATIVE_CHANNEL=latest`; if native install fails and fallback is enabled, npm installs are used. | Native path installs `codex` and `claude` into `~/.local/bin`; npm fallback installs `@openai/codex@latest` and `@anthropic-ai/claude-code@latest`. | `codex --version` and `claude --version` should work. Rerunning the setup updates both CLIs. |
| 9. Configure runtime | Run `scripts/setup-agent-runtime.sh` inside the container. | Local proxy mode requires the LLM Gateway key from step 2. Remote proxy mode only configures client endpoints and optional SSH forwards. If an existing non-generated `~/.codex/config.toml` exists, it is backed up first. | Writes `~/.amd-node-setup/*`, PATH wrappers for `claude` and `codex`, and `~/.codex/config.toml`. | Claude defaults to Opus 4.8 ultracode/xhigh; Codex defaults to GPT 5.5 ultrahigh represented as `xhigh`. |
| 10. Start proxies or forwards | Start two tmux sessions. | `PROXY_BACKEND=local` starts container-local AMDproxy sessions. `PROXY_BACKEND=remote` starts SSH forwards to the paired node when `REMOTE_PROXY_SSH_TARGET` is set. | Local: `amdproxy-claude` on `127.0.0.1:8082` and `amdproxy-codex` on `127.0.0.1:8083`. Remote: `amdproxy-claude-forward` and `amdproxy-codex-forward`. | Claude Code and Codex can route through either local AMD gateway proxies or n0809-hosted proxies. |
| 11. Ready state | Attach and verify before model serving tests. | Do not launch model-specific SGLang commands until the agent inspects the node and target model path. | No more default installs. | Run health checks, inspect `/sgl-workspace/models`, then choose test-specific SGLang launch flags. |

## What This Sets Up

- A ROCm/SGLang dev container selected for MI30x or MI35x class GPUs.
- Docker runtime flags that match the current AMD node workflow, including `--privileged` and `--shm-size 128G`.
- Tooling inside the container: `tmux`, `gh`, Node/npm, Claude Code, Codex CLI, `uv`, Python helpers, and common shell tools.
- Two proxy backends:
  - `PROXY_BACKEND=local`: container-local `tmux` proxy sessions, `amdproxy-claude` on `127.0.0.1:8082` and `amdproxy-codex` on `127.0.0.1:8083`.
  - `PROXY_BACKEND=remote`: container-local `tmux` SSH forwards, `amdproxy-claude-forward` and `amdproxy-codex-forward`, from a TensorWave node to a paired n0809 proxy host.
- Default agent model settings:
  - Claude Code: Opus 4.8 through the AMD gateway, with ultracode enabled by the generated wrapper and `xhigh` sent as the model effort.
  - Codex: GPT 5.5 with Codex `model_reasoning_effort = "xhigh"`, used here as the current Codex config equivalent of the requested ultrahigh setting.

This repo does not launch a model-specific SGLang server by default. The agent should inspect `/sgl-workspace/models` and choose model-specific SGLang flags only after the container exists.

Model weights and caches belong under `/sgl-workspace/models`. The writable workspace mount is `/sgl-workspace/workspace`; the setup does not create or use `/sgl-workspace/workspace/models`.

## Layout

```text
scripts/
  setup-dev-env.sh             # installs tmux, gh, Node/npm, uv, Codex, Claude Code
  setup-agent-runtime.sh       # writes env/config files and starts proxy or forward tmux sessions
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

## Current CLI Installation

Checked on 2026-07-02:

- OpenAI Codex CLI docs recommend the standalone installer on macOS/Linux:
  `curl -fsSL https://chatgpt.com/codex/install.sh | sh`
- OpenAI docs say standalone Codex CLI installs are upgraded by rerunning that installer.
- Claude Code docs recommend native install:
  `curl -fsSL https://claude.ai/install.sh | bash`
- Claude Code native installs auto-update in the background, and `claude update` applies an immediate manual update.
- `@openai/codex@latest` npm metadata reports Node `>=16`.
- `@anthropic-ai/claude-code@latest` npm metadata reports Node `>=18.0.0`.
- This repo still installs Node 20 LTS by default because npm is useful on dev nodes and remains the fallback path for both CLIs.

References:

- OpenAI Codex CLI setup: <https://developers.openai.com/codex/cli>
- OpenAI Codex config basics: <https://developers.openai.com/codex/config-basic>
- OpenAI Codex advanced config: <https://developers.openai.com/codex/config-advanced>
- Anthropic Claude Code setup: <https://code.claude.com/docs/en/setup>
- Anthropic Claude Code model config: <https://code.claude.com/docs/en/model-config>

The bootstrap installs/updates Claude Code and Codex with native installers by default:

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh
curl -fsSL https://claude.ai/install.sh | bash -s latest
```

If the native installer fails in a container, the script falls back to npm unless disabled:

```bash
CODEX_NPM_FALLBACK=0 CLAUDE_NPM_FALLBACK=0 bash scripts/setup-dev-env.sh
```

The npm path can also be selected explicitly:

```bash
CODEX_INSTALL_METHOD=npm CLAUDE_INSTALL_METHOD=npm bash scripts/setup-dev-env.sh
```

GitHub CLI is installed, but authentication is intentionally manual:

```bash
gh auth login
gh auth status
```

## Create a ROCm Dev Container

From this repo on a conductor/AMD-internal host, provide the local proxy inputs:

```bash
CONTAINER_NAME=my-amd-test \
LLM_GATEWAY_API_KEY=REPLACE_WITH_APPLICATION_KEY \
bash docker/start-rocm-dev-container.sh
```

The AMD LLM API Gateway requires a `user: <NTID>` header on every request made
with a shared/app-level API key. Provide your NTID so both proxies attach it:

```bash
CONTAINER_NAME=my-amd-test \
LLM_GATEWAY_API_KEY=REPLACE_WITH_APPLICATION_KEY \
LLM_GATEWAY_USER_NTID=your-ntid \
bash docker/start-rocm-dev-container.sh
```

For requests triggered by an individual user, use that user's NTID; for CI or
automation not triggered by a person, use the service account's NTID.

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
- detect likely model mounts by checking common roots such as `/mnt/dcgpuval`, `/data`, `/models`, `/mnt/models`, `/scratch`, and `~/.cache/huggingface` for real model artifacts
- detect/create a workspace mount
- run `scripts/setup-dev-env.sh` inside the container
- run `scripts/setup-agent-runtime.sh` inside the container
- start local proxy sessions or remote n0809 SSH forward sessions in `tmux`

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

### Create a TensorWave container that uses n0809 proxy

Remote proxy mode is the path for TensorWave nodes such as G45/G46/G05 when the AMDproxy service must run on n0809:

```bash
CONTAINER_NAME=g45-sglang-agent \
PROXY_BACKEND=remote \
REMOTE_PROXY_SSH_TARGET=n0809 \
FORWARD_SSH_AGENT=1 \
bash docker/start-rocm-dev-container.sh
```

The defaults expect n0809 to expose Claude proxy on `127.0.0.1:8082` and Codex/OpenAI-compatible proxy on `127.0.0.1:8083`. Override them if the paired node uses different ports:

```bash
REMOTE_CLAUDE_PROXY_PORT=8882 \
REMOTE_CODEX_PROXY_PORT=8883 \
CONTAINER_NAME=g45-sglang-agent \
PROXY_BACKEND=remote \
REMOTE_PROXY_SSH_TARGET=n0809 \
FORWARD_SSH_AGENT=1 \
bash docker/start-rocm-dev-container.sh
```

When the remote proxy is directly reachable instead of localhost-only on n0809, skip SSH forwards and set explicit client URLs:

```bash
CONTAINER_NAME=g45-sglang-agent \
PROXY_BACKEND=remote \
REMOTE_PROXY_START_SSH_TUNNELS=0 \
CLAUDE_BASE_URL=http://n0809:8082 \
CODEX_BASE_URL=http://n0809:8083/v1 \
bash docker/start-rocm-dev-container.sh
```

## Runtime Files Inside the Container

`scripts/setup-agent-runtime.sh` writes container-local files under `~/.amd-node-setup/`:

```text
amdproxy-claude.env          # local mode Claude proxy settings for port 8082
amdproxy-codex.env           # local mode Codex/OpenAI-compatible proxy settings for port 8083
remote-proxy-claude.env      # remote mode SSH forward settings for Claude
remote-proxy-codex.env       # remote mode SSH forward settings for Codex
start-remote-proxy-forward.sh
claude-env.sh                # Claude Code env
codex-env.sh                 # Codex env
env.sh                       # PATH and shared shell env
bin/claude                   # wrapper around the installed Claude Code binary
bin/codex                    # wrapper around the installed Codex binary
```

`env.sh` also defines a convenience alias for sandboxed, permission-skipping Claude Code sessions:

```bash
alias yolo='IS_SANDBOX=1 claude --dangerously-skip-permissions'
```

It also writes `~/.codex/config.toml` with:

```toml
# Auto-generated by amd-node-setup. This file is container local.
# Codex uses a custom Chat Completions provider because the current AMD
# Gateway Responses path rejects newer Codex metadata fields.
model = "gpt-5.5"
model_provider = "amd_proxy_chat"
model_reasoning_effort = "xhigh"

[model_providers.amd_proxy_chat]
name = "AMD LLM Gateway via OpenAI Chat Completions"
base_url = "http://127.0.0.1:8083/v1"
env_key = "OPENAI_API_KEY"
```

If `~/.codex/config.toml` already exists and was not generated by this repo, it is backed up first.

## Proxy Sessions

Local proxy mode:

```bash
tmux attach -t amdproxy-claude
curl http://127.0.0.1:8082/health
curl http://127.0.0.1:8082/v1/models
tmux attach -t amdproxy-codex
curl http://127.0.0.1:8083/health
curl http://127.0.0.1:8083/v1/models
```

Remote n0809 proxy mode:

```bash
tmux attach -t amdproxy-claude-forward
tmux attach -t amdproxy-codex-forward
curl http://127.0.0.1:8082/health
curl http://127.0.0.1:8083/health
```

The generated wrappers source `~/.amd-node-setup/claude-env.sh` and `~/.amd-node-setup/codex-env.sh`:

```bash
claude
yolo
codex
```

The local Codex proxy defaults to forwarding OpenAI-compatible requests to the SLAI.LLM Gateway Unified OpenAI-compatible base:

```text
https://llm-api.amd.com/Unified/v1
```

If the LLM API Gateway exposes GPT/Codex-compatible models at a different base URL on a specific node/account, pass it while creating the conductor/local-proxy container:

```bash
LLM_GATEWAY_OPENAI_BASE_URL=https://llm-api.amd.com/REPLACE_WITH_OPENAI_COMPATIBLE_BASE \
CONTAINER_NAME=my-amd-test \
LLM_GATEWAY_API_KEY=REPLACE_WITH_APPLICATION_KEY \
bash docker/start-rocm-dev-container.sh
```

For a direct Codex CLI connection to the Unified API, keep the key in environment variables and use a custom provider:

```toml
model_provider = "amd"
model = "GPT-5.3-Codex"

[model_providers.amd]
name = "AMD LLM Gateway"
base_url = "https://llm-api.amd.com/Unified/v1"
env_key = "LLM_GATEWAY_KEY"
env_http_headers = { "Ocp-Apim-Subscription-Key" = "LLM_GATEWAY_KEY" }
```

For a direct Claude Code connection on a conductor node, the equivalent Anthropic-compatible base is `https://llm-api.amd.com/Unified`. Prefer exporting the key and headers from the shell or a node-local secret file rather than committing them:

```bash
export LLM_GATEWAY_KEY=REPLACE_WITH_APPLICATION_KEY
export ANTHROPIC_BASE_URL=https://llm-api.amd.com/Unified
export ANTHROPIC_CUSTOM_HEADERS="Ocp-Apim-Subscription-Key: ${LLM_GATEWAY_KEY}"
export ANTHROPIC_MODEL=default
export ANTHROPIC_DEFAULT_OPUS_MODEL=claude-opus-4-8
```

The g45 container currently uses the local/n0809 proxy URL instead of the direct Unified URL so the API key stays on the conductor side.

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
Detect whether this node is MI30x or MI35x, choose the latest stable rocm720 rocm/sgl-dev image,
mount the local model cache and workspace, install tmux/gh/Claude Code/Codex inside the container,
configure Claude Code through port 8082 and Codex through port 8083, start both proxy tmux sessions,
then attach a tmux session.
Do not commit secrets.
```

For conductor local proxy mode, also provide the LLM Gateway application API key. For TensorWave remote proxy mode, provide `PROXY_BACKEND=remote` and the paired `REMOTE_PROXY_SSH_TARGET` such as n0809 instead of pasting the key onto G45/G46/G05.
