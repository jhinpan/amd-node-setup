# Cursor agent workflow

Human input should be small:

```text
Create a ROCm dev container named <container-name> on this node using the amd-node-runtime repo.
Detect the GPU family, choose the latest stable rocm720 rocm/sgl-dev image, mount the model cache/workspace,
install tmux, gh, Claude Code, and Codex inside the container, and prepare the proxy settings.
Do not commit secrets.
```

Expected agent actions:

1. Clone or update this public repo.
2. Run:

   ```bash
   CONTAINER_NAME=<container-name> bash docker/start-rocm-dev-container.sh
   ```

3. Check the printed summary:

   ```text
   GPU family
   Docker image
   SGLANG_USE_AITER
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
   echo "$SGLANG_USE_AITER"
   ls /sgl-workspace/models
   ```

6. Configure proxy env vars for the selected path:

   ```bash
   export ANTHROPIC_BASE_URL=http://127.0.0.1:8082
   export ANTHROPIC_AUTH_TOKEN=not-used
   export ANTHROPIC_API_KEY=not-used
   export DISABLE_PROMPT_CACHING=1
   ```

7. Only then decide the model-specific SGLang launch command for the test.

Guardrails:

- Do not put API keys in files committed to this repo.
- Prefer env vars or node-local env files outside git.
- If GPU family or mount detection looks wrong, stop and print the detected evidence before launching experiments.
