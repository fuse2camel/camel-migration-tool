#!/usr/bin/env bash
set -euo pipefail

CONTAINER="${CONTAINER:-pgvector}"
POSTGRES_USER="${POSTGRES_USER:-app}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-secret}"
POSTGRES_DB="${POSTGRES_DB:-appdb}"
HOST="${HOST:-localhost}"
PORT="${PORT:-5432}"

log() { printf "\n\033[1;36m%s\033[0m\n" "$*"; }

psql_cmd() {
  PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "${HOST}" -p "${PORT}" -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -v ON_ERROR_STOP=1 "$@"
}

# 1) Read the vector dimension from the table
log "Detecting vector dimension from items.embedding ..."
DIM=$(psql_cmd -Atc "
  SELECT regexp_replace(format_type(a.atttypid, a.atttypmod), 'vector\\((\\d+)\\)', '\\1')::int
  FROM pg_attribute a
  WHERE a.attrelid = 'items'::regclass
    AND a.attname = 'embedding';
")
if [[ -z "${DIM}" ]]; then
  echo "Could not determine vector dimension. Is table 'items' with 'embedding vector(N)' created?" >&2
  exit 1
fi
echo "Detected dimension: ${DIM}"

# 2) Insert two sample rows (only if table is empty)
COUNT=$(psql_cmd -Atc "SELECT COUNT(*) FROM items;")
if [[ "${COUNT}" == "0" ]]; then
  log "Seeding sample rows (dimension=${DIM}) ..."
  psql_cmd -c "
    INSERT INTO items (embedding, doc)
    SELECT
      (ARRAY(
         SELECT round(random()::numeric, 4)::float8
         FROM generate_series(1, ${DIM})
       ))::vector,
      'sample 1';
    INSERT INTO items (embedding, doc)
    SELECT
      (ARRAY(
         SELECT round(random()::numeric, 4)::float8
         FROM generate_series(1, ${DIM})
       ))::vector,
      'sample 2';
  "
else
  echo "Table already has ${COUNT} rows; skipping seed."
fi

# 3) Run a cosine similarity query with a uniform query vector
log "Running cosine-similarity query ..."
psql_cmd -c "
WITH q AS (
  SELECT (ARRAY(SELECT 0.5::float8 FROM generate_series(1, ${DIM})))::vector AS v
)
SELECT id, left(doc, 60) AS doc, (embedding <=> q.v) AS cosine_distance
FROM items, q
ORDER BY embedding <=> q.v
LIMIT 5;
"

echo -e "\nDone."
