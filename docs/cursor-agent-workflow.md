# Cursor agent workflow

Human input should contain the operational values for one proxy mode and node class.

For conductor local proxy mode, such as n0809/0809:

- Docker container name
- LLM Gateway application API key

For TensorWave remote proxy mode, such as G45/G46/G05:

- Docker container name
- `PROXY_BACKEND=remote`
- `REMOTE_PROXY_SSH_TARGET`, usually the paired n0809 SSH target

Conductor local proxy example:

```text
Create a ROCm dev container named <container-name> on this node using the amd-node-setup repo.
The LLM Gateway application API key is: <paste key>.
Detect the GPU family, choose the latest stable rocm720 rocm/sgl-dev image, mount the model cache/workspace,
install tmux, gh, Claude Code, and Codex inside the container, configure Claude Code on port 8082 and Codex on port 8083,
start both AMD proxy tmux sessions, and attach a tmux session.
Do not commit secrets.
```

TensorWave remote proxy example:

```text
Create a ROCm dev container named <container-name> on g45 using the amd-node-setup repo.
Use PROXY_BACKEND=remote and REMOTE_PROXY_SSH_TARGET=n0809 so Claude Code and Codex use the AMDproxy sessions on n0809.
Detect the GPU family, choose the latest stable rocm720 rocm/sgl-dev image, mount the model cache/workspace,
install tmux, gh, Claude Code, and Codex inside the container, configure Claude Code on port 8082 and Codex on port 8083,
start both remote proxy forward tmux sessions, and attach a tmux session.
Do not commit secrets.
```

Expected agent actions:

1. Clone or update this public repo.
2. For conductor local proxy mode, run:

   ```bash
   read -rsp "LLM Gateway application key: " LLM_GATEWAY_API_KEY
   echo
   export LLM_GATEWAY_API_KEY
   CONTAINER_NAME=<container-name> bash docker/start-rocm-dev-container.sh
   ```

   For TensorWave remote proxy mode, run:

   ```bash
   CONTAINER_NAME=<container-name> \
   PROXY_BACKEND=remote \
   REMOTE_PROXY_SSH_TARGET=n0809 \
   FORWARD_SSH_AGENT=1 \
   bash docker/start-rocm-dev-container.sh
   ```

3. Check the printed summary:

   ```text
   GPU family
   Docker image
   Shared memory: 128G
   SGLANG_USE_AITER: 1
   Proxy backend: local or remote
   Claude endpoint: http://127.0.0.1:8082
   Codex endpoint: http://127.0.0.1:8083/v1
   Model cache
   Workspace
   ```

4. Attach:

   ```bash
   docker exec -it <container-name> tmux new -A -s agent
   ```

5. Inside the container, verify tools:

   ```bash
   tmux -V
   gh --version
   claude --version
   codex --version
   echo "$SGLANG_USE_AITER"
   ls /sgl-workspace/models
   ```

6. Verify proxy/runtime setup:

   ```bash
   ls -la ~/.amd-node-setup
   tmux ls
   curl http://127.0.0.1:8082/health
   curl http://127.0.0.1:8083/health
   source ~/.amd-node-setup/env.sh
   env | rg 'ANTHROPIC_BASE_URL|OPENAI_BASE_URL|CODEX_MODEL|SGLANG_USE_AITER'
   ```

7. Confirm generated defaults:

   ```bash
   rg 'gpt-5.5|model_provider|amd_proxy_chat|model_reasoning_effort' ~/.codex/config.toml
   rg 'claude-opus-4-8|CLAUDE_CODE_EFFORT_LEVEL|CLAUDE_ULTRACODE' ~/.amd-node-setup/claude-env.sh
   ```

8. Only then decide the model-specific SGLang launch command for the test.

Guardrails:

- Do not put API keys in files committed to this repo.
- Prefer env vars or node-local env files outside git.
- Do not paste the API key into command lines that will be copied into docs or commits.
- Do not put the LLM Gateway API key on TensorWave nodes such as G45/G46/G05 when a paired n0809 proxy is available.
- Do not set up ad hoc reverse SSH tunnels in this repo; use `PROXY_BACKEND=remote` for TensorWave nodes that need n0809-hosted proxies, or rely on operator-managed tunnels outside git.
- Do not add model-specific SGLang launch presets to the default Docker path.
- If GPU family, Docker image, or mount detection looks wrong, stop and print the detected evidence before launching experiments.
