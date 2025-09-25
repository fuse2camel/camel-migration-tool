#!/usr/bin/env bash
set -euo pipefail

# --- Config ---
CONTAINER_NAME="${CONTAINER_NAME:-vllm}"
IMAGE_NAME="${IMAGE_NAME:-vllm-cpu:local}"

log()  { printf "\n\033[1;36m%s\033[0m\n" "$*"; }
ok()   { printf "\033[1;32m%s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m%s\033[0m\n" "$*"; }

# --- Stop and remove container ---
log "Stopping and removing LLM container..."
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}\$"; then
    docker stop "$CONTAINER_NAME" >/dev/null
    ok "Container '$CONTAINER_NAME' stopped."
else
    warn "Container '$CONTAINER_NAME' not running."
fi

if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}\$"; then
    docker rm "$CONTAINER_NAME" >/dev/null
    ok "Container '$CONTAINER_NAME' removed."
else
    warn "Container '$CONTAINER_NAME' not found."
fi

# --- Remove image if requested ---
if [[ "${1:-}" == "--remove-image" ]]; then
    log "Removing Docker image..."
    if docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "^${IMAGE_NAME}\$"; then
        docker rmi "$IMAGE_NAME" >/dev/null
        ok "Image '$IMAGE_NAME' removed."
    else
        warn "Image '$IMAGE_NAME' not found."
    fi
fi

# --- Clean up build cache if requested ---
if [[ "${1:-}" == "--prune" || "${2:-}" == "--prune" ]]; then
    log "Pruning Docker build cache..."
    docker builder prune -f >/dev/null
    ok "Build cache pruned."
fi

cat <<EOF

------------------------------------------------------------
LLM Service Cleanup Complete ✅

Container: $CONTAINER_NAME - Stopped and removed
Image: $IMAGE_NAME - $(if [[ "${1:-}" == "--remove-image" ]]; then echo "Removed"; else echo "Kept (use --remove-image to remove)"; fi)

Usage:
  ./teardown_llm.sh                    # Stop and remove container only
  ./teardown_llm.sh --remove-image     # Also remove Docker image
  ./teardown_llm.sh --prune            # Also clean build cache
  ./teardown_llm.sh --remove-image --prune  # Full cleanup
------------------------------------------------------------
EOF