# Review notes

Decisions already made:

- Publish as a full public GitHub repo named `amd-node-setup`.
- Split node behavior into two classes:
  - conductor nodes: n0809/0809-style AMD-internal hosts that can hold the LLM Gateway API key and run local proxy sessions
  - TensorWave nodes: G45/G46/G05-style GPU hosts that run ROCm/SGLang workloads and usually consume paired n0809 proxy ports
- Human input contract is mode-specific:
  - conductor local proxy mode: container name and LLM Gateway application API key
  - TensorWave remote proxy mode: container name, `PROXY_BACKEND=remote`, and paired `REMOTE_PROXY_SSH_TARGET`
- Keep `gh auth login` manual.
- Use `SHM_SIZE=128G`.
- Keep `--privileged`.
- Set `SGLANG_USE_AITER=1` by default and make that visible to the user.
- Do not create ad hoc reverse SSH tunnels in this repo; use `PROXY_BACKEND=remote` for SSH local forwards from TensorWave nodes to paired n0809-hosted proxies, or rely on operator-managed tunnels outside git.
- Do not bake model-specific SGLang launch presets into the default Docker flow.
- Let the agent detect model/cache/workspace mount paths on each node.
- Start two proxy or proxy-forward sessions in `tmux`:
  - `amdproxy-claude` on `127.0.0.1:8082`
  - `amdproxy-codex` on `127.0.0.1:8083`
  - or, in remote mode, `amdproxy-claude-forward` and `amdproxy-codex-forward`
- Default Claude Code to Opus 4.8 with ultracode enabled through the generated wrapper.
- Default Codex to GPT 5.5 with Codex `model_reasoning_effort = "xhigh"` for the requested ultrahigh behavior.
- Use native installers as the default install/update path for Claude Code and Codex.
- Keep npm installs available as explicit/fallback paths because Node/npm are useful dependencies on dev nodes.

Still worth validating on a real MI node:

- GPU family detection:
  - MI300/MI300X/MI325 should resolve to `mi30x`.
  - MI350/MI355/gfx950 should resolve to `mi35x`.
- Docker Hub latest-tag selection:
  - Should select the newest tag matching `v*.rocm720-{mi30x|mi35x}-YYYYMMDD`.
  - Should ignore experimental tags such as custom named builds.
- Model cache detection:
  - Current candidates include `/mnt/dcgpuval/huggingface`, `/data/huggingface`, `/data/models`, `/models`, `/mnt/models`, `/scratch/huggingface`, `~/.cache/huggingface`, `/sgl-workspace/models`.
  - Add any canonical AMD node paths after first deployment.
- `setup-dev-env.sh` in the selected `rocm/sgl-dev` image:
  - Confirm apt metadata is available.
  - Confirm native installs land on PATH through `~/.local/bin`.
  - Confirm npm fallback still works when native installers are unavailable.
  - Confirm `claude --version` and `codex --version` work after setup.
- Claude proxy path:
  - `proxy/amd_proxy.py` still uses the confirmed AMD Claude route `/claude3/{model}/chat/completions`.
  - In local mode, confirm the LLM Gateway application key has access to `claude-opus-4-8`.
  - In remote mode, confirm the paired n0809 proxy health check works from g45 through the SSH forward.
- Codex proxy path:
  - The default OpenAI-compatible upstream base is `https://llm-api.amd.com/Unified/v1`.
  - If the real Gateway GPT/Codex endpoint differs, set `LLM_GATEWAY_OPENAI_BASE_URL` when creating the container.
  - Confirm Codex accepts the generated `~/.codex/config.toml` with `model_provider = "amd_proxy_chat"` and sends Chat Completions traffic to `127.0.0.1:8083`.
