#!/usr/bin/env bash
set -euo pipefail

### --- Config (edit as needed) ---
LOCAL_IMAGE="pgvector-local:16"          # try to build from your local Dockerfile
FALLBACK_IMAGE="pgvector/pgvector:pg16"  # prebuilt PG16+pgvector (used if build fails)
CONTAINER="pgvector"
VOLUME="pgvector_data"

POSTGRES_USER="${POSTGRES_USER:-app}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-secret}"
POSTGRES_DB="${POSTGRES_DB:-appdb}"
HOST_PORT="${HOST_PORT:-5432}"

# Vector dimension for your real model (no seeding here)
VECTOR_DIM="${VECTOR_DIM:-768}"

# Extra read-only user
RO_USER="${RO_USER:-readonly}"
RO_PASSWORD="${RO_PASSWORD:-readonly_secret}"

log()  { printf "\n\033[1;36m%s\033[0m\n" "$*"; }
ok()   { printf "\033[1;32m%s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m%s\033[0m\n" "$*"; }

container_exists() { docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER}\$"; }
container_running(){ docker ps --format '{{.Names}}'   | grep -q "^${CONTAINER}\$"; }
volume_exists()    { docker volume ls --format '{{.Name}}' | grep -q "^${VOLUME}\$"; }

wait_for_pg() {
  log "Waiting for PostgreSQL to be ready..."
  for _ in {1..60}; do
    if docker exec -u postgres "${CONTAINER}" pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -h localhost -p 5432 >/dev/null 2>&1; then
      ok "PostgreSQL is ready."
      return 0
    fi
    sleep 1
  done
  echo "PostgreSQL did not become ready in time." >&2
  exit 1
}

psql_exec() {
  docker exec -i "${CONTAINER}" psql -v ON_ERROR_STOP=1 -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -Atc "$1"
}

### --- 0) Sanity check Dockerfile ---
if [[ -f Dockerfile ]]; then
  FIRST_LINE=$(grep -v '^[[:space:]]*$' Dockerfile | grep -v '^[[:space:]]*#' | head -n1 || true)
  if [[ -n "${FIRST_LINE:-}" && "${FIRST_LINE}" != FROM* ]]; then
    warn "Dockerfile first active line is '${FIRST_LINE}' (should start with 'FROM ...'). I'll try to build and fallback if needed."
  fi
fi

### --- 1) Build or fallback ---
USE_IMAGE="$LOCAL_IMAGE"
log "Building local image: ${LOCAL_IMAGE}"
if ! docker build -t "${LOCAL_IMAGE}" .; then
  warn "Local build failed. Falling back to: ${FALLBACK_IMAGE}"
  docker pull "${FALLBACK_IMAGE}"
  USE_IMAGE="${FALLBACK_IMAGE}"
fi

### --- 2) Start container & volume ---
if container_running; then
  log "Container '${CONTAINER}' already running. Skipping start."
else
  if container_exists; then
    log "Removing existing stopped container '${CONTAINER}'..."
    docker rm "${CONTAINER}" >/dev/null
  fi
  if ! volume_exists; then
    log "Creating volume '${VOLUME}'..."
    docker volume create "${VOLUME}" >/dev/null
  fi

  log "Starting container '${CONTAINER}' on port ${HOST_PORT} using image ${USE_IMAGE}..."
  docker run -d --name "${CONTAINER}" \
    -e POSTGRES_USER="${POSTGRES_USER}" \
    -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
    -e POSTGRES_DB="${POSTGRES_DB}" \
    -p "${HOST_PORT}:5432" \
    -v "${VOLUME}:/var/lib/postgresql/data" \
    "${USE_IMAGE}" >/dev/null
fi

wait_for_pg

### --- 3) Provision extension, schema, index, users (idempotent) ---
log "Applying database initialization (no data seeding)..."

# pgvector extension
psql_exec "CREATE EXTENSION IF NOT EXISTS vector;"

# Embeddings table (dimension from VECTOR_DIM)
psql_exec "CREATE TABLE IF NOT EXISTS items (
  id BIGSERIAL PRIMARY KEY,
  embedding vector(${VECTOR_DIM}),
  doc TEXT
);"

# ANN index if missing
IDX=$(psql_exec "SELECT 1 FROM pg_class WHERE relname='items_embedding_ivfflat_idx' LIMIT 1;")
if [[ -z "${IDX}" ]]; then
  psql_exec "CREATE INDEX items_embedding_ivfflat_idx ON items USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);"
fi

# Read-only role & grants
psql_exec "DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${RO_USER}') THEN
    CREATE ROLE ${RO_USER} LOGIN PASSWORD '${RO_PASSWORD}';
  END IF;
END
\$\$;"

psql_exec "GRANT CONNECT ON DATABASE ${POSTGRES_DB} TO ${RO_USER};"
psql_exec "GRANT USAGE ON SCHEMA public TO ${RO_USER};"
psql_exec "GRANT SELECT ON ALL TABLES IN SCHEMA public TO ${RO_USER};"
psql_exec "ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO ${RO_USER};"

### --- 4) Summary ---
PG_VERSION=$(docker exec -i "${CONTAINER}" psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -Atc "SHOW server_version;")
EXTS=$(docker exec -i "${CONTAINER}" psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -Atc "SELECT extname FROM pg_extension ORDER BY 1;")

cat <<EOF

------------------------------------------------------------
PostgreSQL + pgvector is running ✅  (no seed data)

Container:     ${CONTAINER}
Image:         ${USE_IMAGE}
Volume:        ${VOLUME}
PG Version:    ${PG_VERSION}
Extensions:    ${EXTS}

Host:          localhost
Port:          ${HOST_PORT}
Database:      ${POSTGRES_DB}

App user:      ${POSTGRES_USER}
App password:  ${POSTGRES_PASSWORD}

Read-only user:${RO_USER}
RO password:   ${RO_PASSWORD}

psql (app user):
  PGPASSWORD=${POSTGRES_PASSWORD} psql -h localhost -p ${HOST_PORT} -U ${POSTGRES_USER} -d ${POSTGRES_DB}

JDBC URL:
  jdbc:postgresql://localhost:${HOST_PORT}/${POSTGRES_DB}

Change dimensions later?
  - Drop & recreate table with desired N:
      DROP TABLE IF EXISTS items;
      CREATE TABLE items (id BIGSERIAL PRIMARY KEY, embedding vector(${VECTOR_DIM}), doc TEXT);
------------------------------------------------------------
EOF
