# Review notes

Decisions already made:

- Publish as a full public GitHub repo.
- Keep `gh auth login` manual.
- Use `SHM_SIZE=128G`.
- Keep `--privileged`.
- Set `SGLANG_USE_AITER=1` by default and make that visible to the user.
- Do not bake model-specific launch presets into the default Docker flow.
- Let the agent detect model/cache/workspace mount paths on each node.

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
- Proxy path:
  - Confirm whether the default experiment uses `proxy/amd_proxy.py`, LiteLLM, or both.
  - Confirm whether `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`, or both are needed for the exact Claude Code version in use.
