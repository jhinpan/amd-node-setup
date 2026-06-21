# Cursor agent workflow

Human input should contain exactly two operational values:

- Docker container name
- LLM Gateway application API key

Example:

```text
Create a ROCm dev container named <container-name> on this node using the amd-node-runtime repo.
The LLM Gateway application API key is: <paste key>.
Detect the GPU family, choose the latest stable rocm720 rocm/sgl-dev image, mount the model cache/workspace,
install tmux, gh, Claude Code, and Codex inside the container, prepare the proxy settings,
and start AMDproxy in tmux.
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
   SGLANG_USE_AITER
   LLM Gateway key: provided
   Model cache
   Workspace
   ```

4. Attach:

   ```bash
   docker exec -it <container-name> tmux new -A -s agent
   ```

5. Inside the container, verify:

   ```bash
   tmux -V
   gh --version
   claude --version
   codex --version
   gh --version
   echo "$SGLANG_USE_AITER"
   ls /sgl-workspace/models
   ```

6. Verify the proxy/env setup:

   ```bash
   ls -la ~/.amd-node-runtime
   tmux has-session -t amdproxy
   curl http://127.0.0.1:8082/health
   source ~/.amd-node-runtime/claude-env.sh
   env | grep -E 'ANTHROPIC_BASE_URL|DISABLE_PROMPT_CACHING'
   ```

7. Verify both CLIs are ready:

   ```bash
   claude --version
   codex --version
   ```

8. Only then decide the model-specific SGLang launch command for the test.

Guardrails:

- Do not put API keys in files committed to this repo.
- Prefer env vars or node-local env files outside git.
- Do not paste the API key into command lines that will be copied into docs or commits.
- If GPU family or mount detection looks wrong, stop and print the detected evidence before launching experiments.
