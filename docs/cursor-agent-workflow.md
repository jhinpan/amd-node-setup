# Cursor agent workflow

Human input should contain exactly two operational values:

- Docker container name
- LLM Gateway application API key

Example:

```text
Create a ROCm dev container named <container-name> on this node using the amd-node-setup repo.
The LLM Gateway application API key is: <paste key>.
Detect the GPU family, choose the latest stable rocm720 rocm/sgl-dev image, mount the model cache/workspace,
install tmux, gh, Claude Code, and Codex inside the container, configure Claude Code on port 8082 and Codex on port 8083,
start both AMD proxy tmux sessions, and attach a tmux session.
Do not commit secrets.
```

Expected agent actions:

1. Clone or update this public repo.
2. Run:

   ```bash
   read -rsp "LLM Gateway application key: " LLM_GATEWAY_API_KEY
   echo
   export LLM_GATEWAY_API_KEY
   CONTAINER_NAME=<container-name> bash docker/start-rocm-dev-container.sh
   ```

3. Check the printed summary:

   ```text
   GPU family
   Docker image
   Shared memory: 128G
   SGLANG_USE_AITER: 1
   Claude proxy: 127.0.0.1:8082
   Codex proxy: 127.0.0.1:8083
   LLM Gateway key: provided
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
   tmux has-session -t amdproxy-claude
   tmux has-session -t amdproxy-codex
   curl http://127.0.0.1:8082/health
   curl http://127.0.0.1:8083/health
   source ~/.amd-node-setup/env.sh
   env | rg 'ANTHROPIC_BASE_URL|OPENAI_BASE_URL|CODEX_MODEL|SGLANG_USE_AITER'
   ```

7. Confirm generated defaults:

   ```bash
   rg 'gpt-5.5|model_reasoning_effort|openai_base_url' ~/.codex/config.toml
   rg 'claude-opus-4-8|CLAUDE_CODE_EFFORT_LEVEL|CLAUDE_ULTRACODE' ~/.amd-node-setup/claude-env.sh
   ```

8. Only then decide the model-specific SGLang launch command for the test.

Guardrails:

- Do not put API keys in files committed to this repo.
- Prefer env vars or node-local env files outside git.
- Do not paste the API key into command lines that will be copied into docs or commits.
- Do not set up reverse SSH tunnels for this repo.
- Do not add model-specific SGLang launch presets to the default Docker path.
- If GPU family, Docker image, or mount detection looks wrong, stop and print the detected evidence before launching experiments.
