#!/usr/bin/env bash
set -euo pipefail

# --- Config (override via env) ---
IMAGE_NAME="${IMAGE_NAME:-vllm-cpu:local}"
CONTAINER_NAME="${CONTAINER_NAME:-vllm}"
HOST_PORT="${HOST_PORT:-8000}"
MODEL="${MODEL:-Qwen/Qwen2.5-1.5B-Instruct}"
OMP_NUM_THREADS="${OMP_NUM_THREADS:-8}"

# Docker resource limits
DOCKER_MEMORY="${DOCKER_MEMORY:-8g}"       # 8GB memory limit
DOCKER_CPUS="${DOCKER_CPUS:-4.0}"          # 4 CPU cores

HF_CACHE_HOST="${HF_CACHE_HOST:-$HOME/.cache/huggingface}"
HF_CACHE_CONT="/root/.cache/huggingface"

log()  { printf "\n\033[1;36m%s\033[0m\n" "$*"; }
ok()   { printf "\033[1;32m%s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m%s\033[0m\n" "$*"; }

# --- 0) Ensure Docker daemon is up (auto-start Desktop on macOS) ---
ensure_docker() {
  if docker info >/dev/null 2>&1; then return 0; fi
  case "$(uname -s)" in
    Darwin)
      pgrep -f "Docker Desktop" >/dev/null 2>&1 || open -a Docker || true
      log "Waiting for Docker Desktop…"
      for _ in $(seq 1 90); do docker info >/dev/null 2>&1 && return 0 || sleep 1; done
      echo "Docker daemon not ready. Open Docker Desktop and retry." >&2; exit 1;;
    *) echo "Docker daemon not reachable. Start Docker and retry." >&2; exit 1;;
  esac
}
ensure_docker

# --- 1) Robust arch selection (handles Rosetta) ---
OS="$(uname -s)"
IS_MAC_ARM=0; IS_ROSETTA=0
if [ "$OS" = "Darwin" ]; then
  [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = "1" ] && IS_MAC_ARM=1
  [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = "1" ] && IS_ROSETTA=1
fi

pick_arm() { DOCKERFILE="Dockerfile.vllm-arm64"; PLATFORM="linux/arm64"; }
pick_amd() { DOCKERFILE="Dockerfile.vllm-amd64"; PLATFORM="linux/amd64"; }

# Allow manual override via UNAME_M environment variable
if [ -n "${UNAME_M:-}" ]; then
  case "$UNAME_M" in
    arm64|aarch64) pick_arm ;;
    amd64|x86_64) pick_amd ;;
    *) warn "Unknown UNAME_M value: $UNAME_M, defaulting to amd64"; pick_amd ;;
  esac
elif [ "$IS_MAC_ARM" = "1" ]; then
  pick_arm
  [ "$IS_ROSETTA" = "1" ] && warn "Rosetta detected; using arm64 build."
else
  case "$(uname -m)" in arm64|aarch64) pick_arm ;; x86_64|amd64) pick_amd ;; *) pick_amd ;; esac
fi

[ -f "$DOCKERFILE" ] || { echo "Missing $DOCKERFILE"; exit 1; }
export DOCKER_DEFAULT_PLATFORM="$PLATFORM"
log "Arch → $DOCKERFILE  (--platform $PLATFORM)"

# --- 2) Build with safe fallbacks (don't touch DOCKER_CONFIG) ---
try_build() {
  log "Building image: $IMAGE_NAME"
  set +e
  DOCKER_BUILDKIT=1 docker build --pull -f "$DOCKERFILE" --platform "$PLATFORM" -t "$IMAGE_NAME" . 2>build.err
  rc=$?
  set -e
  if [ $rc -eq 0 ]; then rm -f build.err; return 0; fi

  if grep -qi "error getting credentials" build.err; then
    # Retry with empty registry auth ONLY (keeps contexts intact)
    warn "Credential helper issue → retrying with DOCKER_AUTH_CONFIG and legacy builder…"
    DOCKER_AUTH_CONFIG='{"auths":{}}' DOCKER_BUILDKIT=0 \
      docker build --pull -f "$DOCKERFILE" --platform "$PLATFORM" -t "$IMAGE_NAME" .
    rm -f build.err; ok "Build succeeded with DOCKER_AUTH_CONFIG + legacy builder."; return 0
  fi

  if grep -qi "buildx component is missing" build.err; then
    warn "BuildKit/buildx missing → retrying with legacy builder…"
    DOCKER_BUILDKIT=0 docker build --pull -f "$DOCKERFILE" --platform "$PLATFORM" -t "$IMAGE_NAME" .
    rm -f build.err; ok "Build succeeded with legacy builder."; return 0
  fi

  if docker buildx version >/dev/null 2>&1; then
    warn "Retrying with docker buildx build…"
    docker buildx build --load --pull -f "$DOCKERFILE" --platform "$PLATFORM" -t "$IMAGE_NAME" .
    rm -f build.err; ok "Build succeeded with buildx."; return 0
  fi

  echo "Build failed. See build.err:"; cat build.err; exit 1
}
try_build

# --- 3) Stop/remove any old container ---
docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}\$" && docker stop "$CONTAINER_NAME" >/dev/null || true
docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}\$" && docker rm "$CONTAINER_NAME"   >/dev/null || true

mkdir -p "$HF_CACHE_HOST"

# --- 4) Run LLM service (OpenAI-compatible API on :8000) ---
log "Starting LLM service: $MODEL"
if [[ "$DOCKERFILE" == *"arm64"* ]]; then
  # ARM64 uses transformers-based API server (no vLLM)
  docker run -d --name "$CONTAINER_NAME" \
    --memory="$DOCKER_MEMORY" \
    --cpus="$DOCKER_CPUS" \
    -e MODEL="$MODEL" \
    -e OMP_NUM_THREADS="$OMP_NUM_THREADS" \
    -p "$HOST_PORT:8000" \
    -v "$HF_CACHE_HOST:$HF_CACHE_CONT" \
    "$IMAGE_NAME" >/dev/null
else
  # AMD64 uses vLLM
  docker run -d --name "$CONTAINER_NAME" \
    --memory="$DOCKER_MEMORY" \
    --cpus="$DOCKER_CPUS" \
    -e MODEL="$MODEL" \
    -e OMP_NUM_THREADS="$OMP_NUM_THREADS" \
    -e CUDA_VISIBLE_DEVICES="" \
    -e VLLM_TARGET_DEVICE=cpu \
    -e VLLM_USE_MODELSCOPE=false \
    -e VLLM_LOGGING_LEVEL=INFO \
    -e VLLM_CPU_KVCACHE_SPACE=40 \
    -p "$HOST_PORT:8000" \
    -v "$HF_CACHE_HOST:$HF_CACHE_CONT" \
    "$IMAGE_NAME" \
    python -m vllm.entrypoints.openai.api_server --model "$MODEL" --device cpu --host 0.0.0.0 --port 8000 >/dev/null
fi

# --- 5) Check if container is running and show logs if it fails ---
sleep 5
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}\$"; then
  warn "Container failed to start. Here are the logs:"
  docker logs "$CONTAINER_NAME"
  echo ""
  warn "Trying alternative startup command..."
  
  # Try alternative startup command
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  if [[ "$DOCKERFILE" == *"arm64"* ]]; then
    # ARM64 uses transformers-based API server
    docker run -d --name "$CONTAINER_NAME" \
      --memory="$DOCKER_MEMORY" \
      --cpus="$DOCKER_CPUS" \
      -e MODEL="$MODEL" \
      -e OMP_NUM_THREADS="$OMP_NUM_THREADS" \
      -p "$HOST_PORT:8000" \
      -v "$HF_CACHE_HOST:$HF_CACHE_CONT" \
      "$IMAGE_NAME" \
      python -u openai_api_server.py >/dev/null
  else
    # AMD64 uses vLLM
    docker run -d --name "$CONTAINER_NAME" \
      --memory="$DOCKER_MEMORY" \
      --cpus="$DOCKER_CPUS" \
      -e MODEL="$MODEL" \
      -e OMP_NUM_THREADS="$OMP_NUM_THREADS" \
      -e CUDA_VISIBLE_DEVICES="" \
      -e VLLM_TARGET_DEVICE=cpu \
      -e VLLM_LOGGING_LEVEL=DEBUG \
      -e VLLM_USE_MODELSCOPE=false \
      -p "$HOST_PORT:8000" \
      -v "$HF_CACHE_HOST:$HF_CACHE_CONT" \
      "$IMAGE_NAME" \
      python -m vllm.entrypoints.openai.api_server --model "$MODEL" --device cpu --host 0.0.0.0 --port 8000 >/dev/null
  fi
  
  sleep 10
  if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}\$"; then
    warn "Still failed. Full debug logs:"
    docker logs "$CONTAINER_NAME"
    exit 1
  fi
fi

ok "vLLM is up."

cat <<EOF

------------------------------------------------------------
vLLM server (OpenAI-compatible)

Container:   $CONTAINER_NAME
Image:       $IMAGE_NAME
Dockerfile:  $DOCKERFILE
Platform:    $PLATFORM
Port:        $HOST_PORT
Model:       $MODEL
Threads:     OMP_NUM_THREADS=$OMP_NUM_THREADS
Memory:      $DOCKER_MEMORY
CPUs:        $DOCKER_CPUS

Check logs:
  docker logs $CONTAINER_NAME

Test:
  curl http://localhost:$HOST_PORT/v1/chat/completions \\
    -H "Content-Type: application/json" \\
    -H "Authorization: Bearer dummy" \\
    -d '{
      "model":"$MODEL",
      "messages":[{"role":"user","content":"Two facts about Sydney?"}],
      "max_tokens":64
    }' | jq .

Stop:
  docker stop $CONTAINER_NAME
------------------------------------------------------------
EOF