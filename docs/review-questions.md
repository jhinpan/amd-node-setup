# Review notes

Decisions already made:

- Publish as a full public GitHub repo named `amd-node-setup`.
- Human input contract is two values: container name and LLM Gateway application API key.
- Keep `gh auth login` manual.
- Use `SHM_SIZE=128G`.
- Keep `--privileged`.
- Set `SGLANG_USE_AITER=1` by default and make that visible to the user.
- Do not create reverse SSH tunnels.
- Do not bake model-specific SGLang launch presets into the default Docker flow.
- Let the agent detect model/cache/workspace mount paths on each node.
- Start two proxy sessions in `tmux`:
  - `amdproxy-claude` on `127.0.0.1:8082`
  - `amdproxy-codex` on `127.0.0.1:8083`
- Default Claude Code to Opus 4.8 with ultracode enabled through the generated wrapper.
- Default Codex to GPT 5.5 with Codex `model_reasoning_effort = "xhigh"` for the requested ultrahigh behavior.

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
  - Confirm npm global installs land on PATH.
  - Confirm `claude --version` and `codex --version` work after setup.
- Claude proxy path:
  - `proxy/amd_proxy.py` still uses the confirmed AMD Claude route `/claude3/{model}/chat/completions`.
  - Confirm the LLM Gateway application key has access to `claude-opus-4-8`.
- Codex proxy path:
  - The default OpenAI-compatible upstream base is `https://llm-api.amd.com/v1`.
  - If the real Gateway GPT/Codex endpoint differs, set `LLM_GATEWAY_OPENAI_BASE_URL` when creating the container.
  - Confirm Codex accepts the generated `~/.codex/config.toml` and sends traffic to `127.0.0.1:8083`.
