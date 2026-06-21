#!/usr/bin/env bash
set -Eeuo pipefail

# Create a generic ROCm SGLang dev container for agent work.
#
# Required human inputs:
#   CONTAINER_NAME=my-test
#   LLM_GATEWAY_API_KEY=<application key from the LLM API Gateway>
#
# The intended workflow is:
#   CONTAINER_NAME=my-test LLM_GATEWAY_API_KEY=... bash docker/start-rocm-dev-container.sh
# Then attach:
#   docker exec -it my-test tmux new -A -s agent
#
# The script auto-detects:
#   - MI30x vs MI35x GPU family
#   - latest stable rocm720 rocm/sgl-dev image for that family
#   - likely model cache and workspace mount paths
#
# It also exports SGLang ROCm defaults into the container:
#   SGLANG_USE_AITER=1
#   SGLANG_ROCM_FUSED_DECODE_MLA=0

CONTAINER_NAME="${CONTAINER_NAME:-}"
LLM_GATEWAY_API_KEY="${LLM_GATEWAY_API_KEY:-${AMD_LLM_API_KEY:-}}"
LLM_GATEWAY_BASE_URL="${LLM_GATEWAY_BASE_URL:-https://llm-api.amd.com}"
LLM_GATEWAY_OPENAI_BASE_URL="${LLM_GATEWAY_OPENAI_BASE_URL:-${AMD_OPENAI_BASE_URL:-}}"
SHM_SIZE="${SHM_SIZE:-128G}"
HIP_VISIBLE_DEVICES="${HIP_VISIBLE_DEVICES:-0,1,2,3,4,5,6,7}"
SGLANG_USE_AITER="${SGLANG_USE_AITER:-1}"
SGLANG_ROCM_FUSED_DECODE_MLA="${SGLANG_ROCM_FUSED_DECODE_MLA:-0}"
CLAUDE_PROXY_PORT="${CLAUDE_PROXY_PORT:-8082}"
CODEX_PROXY_PORT="${CODEX_PROXY_PORT:-8083}"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-opus-4-8}"
CLAUDE_EFFORT="${CLAUDE_EFFORT:-xhigh}"
CLAUDE_ULTRACODE="${CLAUDE_ULTRACODE:-1}"
CODEX_MODEL="${CODEX_MODEL:-gpt-5.5}"
CODEX_REASONING_EFFORT="${CODEX_REASONING_EFFORT:-xhigh}"
CODEX_REASONING_LABEL="${CODEX_REASONING_LABEL:-ultrahigh}"
INSTALL_TOOLS="${INSTALL_TOOLS:-1}"
DRY_RUN="${DRY_RUN:-0}"
KEEP_CONTAINER_ALIVE_CMD="${KEEP_CONTAINER_ALIVE_CMD:-while true; do sleep 3600; done}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

have() { command -v "$1" >/dev/null 2>&1; }

if [[ -z "${CONTAINER_NAME}" ]]; then
  echo "ERROR: CONTAINER_NAME is required" >&2
  echo "Example: CONTAINER_NAME=my-test LLM_GATEWAY_API_KEY=... bash docker/start-rocm-dev-container.sh" >&2
  exit 1
fi

if [[ -z "${LLM_GATEWAY_API_KEY}" ]]; then
  echo "ERROR: LLM_GATEWAY_API_KEY is required" >&2
  echo "Provide the application API key from the LLM API Gateway." >&2
  exit 1
fi

detect_gpu_family() {
  if [[ -n "${GPU_FAMILY:-}" ]]; then
    echo "${GPU_FAMILY}"
    return
  fi

  local text=""
  if have rocm-smi; then
    text+=" $(rocm-smi --showproductname 2>/dev/null || true)"
  fi
  if have rocminfo; then
    text+=" $(rocminfo 2>/dev/null | grep -E 'Marketing Name|Name:.*gfx' || true)"
  fi
  if have lspci; then
    text+=" $(lspci 2>/dev/null | grep -Ei 'AMD|MI3|MI2|Instinct' || true)"
  fi

  if grep -Eiq 'MI35|MI350|MI355|gfx95|gfx950' <<< "${text}"; then
    echo "mi35x"
  elif grep -Eiq 'MI30|MI300|MI325|gfx94|gfx942' <<< "${text}"; then
    echo "mi30x"
  else
    echo "mi35x"
    echo "WARN: could not detect GPU family; defaulting GPU_FAMILY=mi35x" >&2
  fi
}

latest_rocm720_image() {
  local family="$1"
  local fallback="rocm/sgl-dev:v0.5.13.post1-rocm720-${family}-20260620"

  if [[ -n "${IMAGE:-}" ]]; then
    echo "${IMAGE}"
    return
  fi

  if ! have curl || ! have python3; then
    echo "${fallback}"
    return
  fi

  local tag
  tag="$(
    curl -fsSL "https://hub.docker.com/v2/repositories/rocm/sgl-dev/tags?page_size=100&name=rocm720-${family}" 2>/dev/null \
      | python3 -c '
import json, re, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
pattern = re.compile(r"^v[0-9].*rocm720-'"${family}"'-[0-9]{8}$")
results = [
    (item.get("last_updated") or "", item.get("name") or "")
    for item in data.get("results", [])
    if pattern.match(item.get("name") or "")
]
results.sort(reverse=True)
if results:
    print(results[0][1])
' 2>/dev/null || true
  )"

  if [[ -n "${tag}" ]]; then
    echo "rocm/sgl-dev:${tag}"
  else
    echo "${fallback}"
  fi
}

first_existing_dir() {
  local candidate
  for candidate in "$@"; do
    if [[ -n "${candidate}" && -d "${candidate}" ]]; then
      echo "${candidate}"
      return 0
    fi
  done
  return 1
}

detect_model_cache() {
  if [[ -n "${HOST_MODEL_CACHE:-}" ]]; then
    echo "${HOST_MODEL_CACHE}"
    return
  fi

  first_existing_dir \
    /mnt/dcgpuval/huggingface \
    /mnt/dcgpuval/models \
    /data/huggingface \
    /data/models \
    /models \
    /mnt/models \
    /scratch/huggingface \
    "${HOME:-}/.cache/huggingface" \
    /sgl-workspace/models \
    || {
      echo ""
      echo "WARN: no model cache directory detected; container will start without a model cache mount" >&2
    }
}

detect_workspace() {
  if [[ -n "${HOST_WORKSPACE:-}" ]]; then
    echo "${HOST_WORKSPACE}"
    return
  fi

  if [[ -d /mnt/dcgpuval && -w /mnt/dcgpuval ]]; then
    echo /mnt/dcgpuval/sgl-workspace
  elif [[ -d /workspace && -w /workspace ]]; then
    echo /workspace
  elif [[ -n "${HOME:-}" ]]; then
    echo "${HOME}/sgl-workspace"
  else
    echo /tmp/sgl-workspace
  fi
}

gpu_family="$(detect_gpu_family)"
image="$(latest_rocm720_image "${gpu_family}")"
model_cache="$(detect_model_cache)"
workspace="$(detect_workspace)"
if [[ "${DRY_RUN}" != "1" ]]; then
  mkdir -p "${workspace}"
fi

docker_args=(
  run -d
  --name "${CONTAINER_NAME}"
  --restart unless-stopped
  --network=host
  --ipc=host
  --privileged
  --shm-size "${SHM_SIZE}"
  --cap-add=CAP_SYS_ADMIN
  --cap-add=SYS_PTRACE
  --device=/dev/kfd
  --device=/dev/dri
  --group-add video
  --security-opt seccomp=unconfined
  --security-opt apparmor=unconfined
  -e HIP_VISIBLE_DEVICES="${HIP_VISIBLE_DEVICES}"
  -e SGLANG_USE_AITER="${SGLANG_USE_AITER}"
  -e SGLANG_ROCM_FUSED_DECODE_MLA="${SGLANG_ROCM_FUSED_DECODE_MLA}"
  -e LLM_GATEWAY_API_KEY="${LLM_GATEWAY_API_KEY}"
  -e AMD_LLM_API_KEY="${LLM_GATEWAY_API_KEY}"
  -e LLM_GATEWAY_BASE_URL="${LLM_GATEWAY_BASE_URL}"
  -e AMD_LLM_BASE_URL="${LLM_GATEWAY_BASE_URL}"
  -e CLAUDE_PROXY_PORT="${CLAUDE_PROXY_PORT}"
  -e CODEX_PROXY_PORT="${CODEX_PROXY_PORT}"
  -e CLAUDE_MODEL="${CLAUDE_MODEL}"
  -e CLAUDE_EFFORT="${CLAUDE_EFFORT}"
  -e CLAUDE_ULTRACODE="${CLAUDE_ULTRACODE}"
  -e CODEX_MODEL="${CODEX_MODEL}"
  -e CODEX_REASONING_EFFORT="${CODEX_REASONING_EFFORT}"
  -e CODEX_REASONING_LABEL="${CODEX_REASONING_LABEL}"
  -e HF_HOME=/sgl-workspace/models
  -e AMD_NODE_SETUP_REPO=/opt/amd-node-setup
  -e AMD_NODE_RUNTIME_REPO=/opt/amd-node-setup
  -v "${repo_root}:/opt/amd-node-setup:ro"
  -v "${workspace}:/sgl-workspace/workspace"
)

if [[ -n "${model_cache}" ]]; then
  docker_args+=(-v "${model_cache}:/sgl-workspace/models")
fi

if [[ -n "${LLM_GATEWAY_OPENAI_BASE_URL}" ]]; then
  docker_args+=(-e "LLM_GATEWAY_OPENAI_BASE_URL=${LLM_GATEWAY_OPENAI_BASE_URL}")
fi

if [[ "${INSTALL_TOOLS}" == "1" ]]; then
  container_cmd="/opt/amd-node-setup/scripts/setup-dev-env.sh && /opt/amd-node-setup/scripts/setup-agent-runtime.sh && ${KEEP_CONTAINER_ALIVE_CMD}"
else
  container_cmd="/opt/amd-node-setup/scripts/setup-agent-runtime.sh && ${KEEP_CONTAINER_ALIVE_CMD}"
fi

echo "GPU family       : ${gpu_family}"
echo "Docker image     : ${image}"
echo "Container name   : ${CONTAINER_NAME}"
echo "Shared memory    : ${SHM_SIZE}"
echo "SGLANG_USE_AITER : ${SGLANG_USE_AITER}"
echo "Claude proxy     : 127.0.0.1:${CLAUDE_PROXY_PORT} (${CLAUDE_MODEL}, ultracode/${CLAUDE_EFFORT})"
echo "Codex proxy      : 127.0.0.1:${CODEX_PROXY_PORT} (${CODEX_MODEL}, ${CODEX_REASONING_LABEL}/${CODEX_REASONING_EFFORT})"
echo "LLM Gateway key  : provided"
echo "Model cache      : ${model_cache:-<none detected>}"
echo "Workspace        : ${workspace}"

if [[ "${DRY_RUN}" == "1" ]]; then
  sanitized_docker_args=("${docker_args[@]}")
  for i in "${!sanitized_docker_args[@]}"; do
    case "${sanitized_docker_args[$i]}" in
      LLM_GATEWAY_API_KEY=*|AMD_LLM_API_KEY=*)
        sanitized_docker_args[$i]="${sanitized_docker_args[$i]%%=*}=<redacted>"
        ;;
    esac
  done

  echo
  echo "Dry run docker command:"
  printf 'docker'
  printf ' %q' "${sanitized_docker_args[@]}" "${image}" bash -lc "${container_cmd}"
  printf '\n'
  exit 0
fi

docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
docker "${docker_args[@]}" "${image}" bash -lc "${container_cmd}"

echo
echo "Started ${CONTAINER_NAME}"
echo "Attach: docker exec -it ${CONTAINER_NAME} tmux new -A -s agent"
echo "Logs  : docker logs -f ${CONTAINER_NAME}"
