#!/usr/bin/env bash
set -euo pipefail

# ---- Config (override via env) ----
CONTAINER="${CONTAINER:-pgvector}"
VOLUME="${VOLUME:-pgvector_data}"
LOCAL_IMAGE="${LOCAL_IMAGE:-pgvector-local:16}"
FALLBACK_IMAGE="${FALLBACK_IMAGE:-pgvector/pgvector:pg16}"

# When --zap is used, these patterns are used to match artifacts (case-insensitive, extended regex)
ZAP_PATTERNS="${ZAP_PATTERNS:-pgvector|vectordb}"

DELETE_FILES="${DELETE_FILES:-true}"    # consider local Dockerfile/initdb for deletion
FORCE="false"
DO_ZAP="false"
PRUNE_BUILD_CACHE="false"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  -f, --force               Do not prompt for confirmations
      --zap                 Remove ALL containers/images/volumes/networks whose name matches /(pgvector|vectordb)/i
      --prune-build-cache   Also prune Docker build cache (global; not pattern-scoped)
  -h, --help                Show this help

Env overrides:
  CONTAINER, VOLUME, LOCAL_IMAGE, FALLBACK_IMAGE, ZAP_PATTERNS, DELETE_FILES
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    -f|--force) FORCE="true" ;;
    --zap) DO_ZAP="true" ;;
    --prune-build-cache) PRUNE_BUILD_CACHE="true" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

# ---- Helpers ----
log()  { printf "\n\033[1;36m%s\033[0m\n" "$*"; }
ok()   { printf "\033[1;32m%s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m%s\033[0m\n" "$*"; }

confirm() {
  local prompt="$1"
  if [ "${FORCE}" = "true" ]; then
    return 0
  fi
  printf "%s [y/N]: " "$prompt"
  read -r ans || true
  case "${ans:-}" in
    y|Y) return 0 ;;
    *)   return 1 ;;
  esac
}

container_exists() { docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER}\$" || true; }
container_running(){ docker ps    --format '{{.Names}}' | grep -q "^${CONTAINER}\$" || true; }
volume_exists()    { docker volume ls --format '{{.Name}}' | grep -q "^${VOLUME}\$" || true; }

remove_lines_as() {
  # $1 = kind (container|image|volume|network)
  # stdin = newline-separated IDs to remove
  kind="$1"
  ids="$(cat)"
  if [ -z "${ids}" ]; then
    return 0
  fi
  log "Removing ${kind}(s):"
  echo "${ids}"
  case "${kind}" in
    container) echo "${ids}" | xargs -n 1 docker rm -f >/dev/null 2>&1 || true ;;
    image)     echo "${ids}" | xargs -n 1 docker rmi   >/dev/null 2>&1 || true ;;
    volume)    echo "${ids}" | xargs -n 1 docker volume rm >/dev/null 2>&1 || true ;;
    network)   echo "${ids}" | xargs -n 1 docker network rm >/dev/null 2>&1 || true ;;
  esac
}

# ---- 1) Stop & remove the primary container ----
if container_running; then
  log "Stopping container: ${CONTAINER}"
  docker stop "${CONTAINER}" >/dev/null || true
fi

if container_exists; then
  log "Removing container: ${CONTAINER}"
  docker rm "${CONTAINER}" >/dev/null || true
else
  warn "Container '${CONTAINER}' not found; skipping."
fi

# ---- 2) Remove the primary volume ----
if volume_exists; then
  log "Removing volume: ${VOLUME}"
  docker volume rm "${VOLUME}" >/dev/null || true
else
  warn "Volume '${VOLUME}' not found; skipping."
fi

# ---- 3) Remove the known images ----
log "Removing images (if present): ${LOCAL_IMAGE}, ${FALLBACK_IMAGE}"
docker rmi "${LOCAL_IMAGE}"    >/dev/null 2>&1 || true
docker rmi "${FALLBACK_IMAGE}" >/dev/null 2>&1 || true

# ---- 4) ZAP mode: remove anything matching patterns ----
if [ "${DO_ZAP}" = "true" ]; then
  log "ZAP mode enabled. Target pattern: /${ZAP_PATTERNS}/i"

  # Containers (stopped + running)
  docker ps -a --format '{{.ID}} {{.Names}}' \
    | grep -iE "${ZAP_PATTERNS}" \
    | awk '{print $1}' \
    | remove_lines_as container

  # Volumes
  docker volume ls --format '{{.Name}}' \
    | grep -iE "${ZAP_PATTERNS}" \
    | remove_lines_as volume

  # Networks
  docker network ls --format '{{.Name}}' \
    | grep -iE "${ZAP_PATTERNS}" \
    | remove_lines_as network

  # Images (match on repo:tag OR ID line if the repository/tag matches)
  docker images -a --format '{{.Repository}}:{{.Tag}} {{.ID}}' \
    | grep -iE "${ZAP_PATTERNS}" \
    | awk '{print $2}' \
    | remove_lines_as image
fi

# ---- 5) Optional: prune build cache (global) ----
if [ "${PRUNE_BUILD_CACHE}" = "true" ]; then
  if confirm "Prune Docker build cache (global)?"; then
    log "Pruning build cache (docker builder prune -f)"
    docker builder prune -f >/dev/null || true
    log "Pruning dangling images (docker image prune -f)"
    docker image prune -f >/dev/null || true
    log "Pruning unused volumes (docker volume prune -f)"
    docker volume prune -f >/dev/null || true
    log "Pruning unused networks (docker network prune -f)"
    docker network prune -f >/dev/null || true
  else
    warn "Skipped pruning build cache."
  fi
fi

# ---- 6) Optionally delete local Dockerfile & initdb/ ----
if [ "${DELETE_FILES}" = "true" ]; then
  to_delete=""
  [ -f "Dockerfile" ] && to_delete="${to_delete} Dockerfile"
  [ -d "initdb"     ] && to_delete="${to_delete} initdb/"
  if [ -n "${to_delete}" ]; then
    if confirm "Delete local files:${to_delete}?"; then
      for p in ${to_delete}; do
        log "Deleting ${p}"
        rm -rf -- "${p}"
      done
      ok "Local docker files removed."
    else
      warn "Skipping deletion of local files."
    fi
  fi
fi

ok "Teardown complete."
echo "Verify with: docker ps -a ; docker images -a ; docker volume ls ; docker network ls"
