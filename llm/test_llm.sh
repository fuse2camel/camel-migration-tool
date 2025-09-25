#!/usr/bin/env bash
set -euo pipefail

# --- Config ---
HOST_PORT="${HOST_PORT:-8000}"
CONTAINER_NAME="${CONTAINER_NAME:-vllm}"
MODEL="${MODEL:-Qwen/Qwen2.5-1.5B-Instruct}"

log()  { printf "\n\033[1;36m%s\033[0m\n" "$*"; }
ok()   { printf "\033[1;32m%s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m%s\033[0m\n" "$*"; }
error() { printf "\033[1;31m%s\033[0m\n" "$*"; }

# --- Check if container is running ---
log "Checking LLM service status..."
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}\$"; then
    error "Container '$CONTAINER_NAME' is not running!"
    echo "Run './setup_llm.sh' first to start the service."
    exit 1
fi

ok "Container '$CONTAINER_NAME' is running."

# --- Test health endpoint ---
log "Testing health endpoint..."
if curl -s "http://localhost:${HOST_PORT}/health" >/dev/null; then
    ok "Health check passed ✅"
else
    error "Health check failed ❌"
    exit 1
fi

# --- Test models endpoint ---
log "Testing models endpoint..."
if curl -s "http://localhost:${HOST_PORT}/v1/models" | grep -q "\"object\""; then
    ok "Models endpoint working ✅"
else
    error "Models endpoint failed ❌"
    exit 1
fi

# --- Performance test with timing ---
log "Running performance test..."
echo "Testing chat completion with optimized settings..."

# Measure response time
start_time=$(date +%s.%3N)
response=$(curl -s "http://localhost:${HOST_PORT}/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer dummy" \
  -d '{
    "model":"'"$MODEL"'",
    "messages":[{"role":"user","content":"Hello, how are you?"}],
    "max_tokens":32,
    "temperature":0.1
  }')
end_time=$(date +%s.%3N)

# Calculate response time
response_time=$(echo "$end_time - $start_time" | bc)

# Check if response is valid JSON
if echo "$response" | jq . >/dev/null 2>&1; then
    ok "Chat completion successful ✅"
    echo "Response time: ${response_time}s"
    echo
    echo "Response content:"
    echo "$response" | jq -r '.choices[0].message.content'
    echo
    echo "Usage stats:"
    echo "$response" | jq '.usage'
else
    error "Chat completion failed ❌"
    echo "Raw response: $response"
    exit 1
fi

# --- Container resource usage ---
log "Container resource usage:"
docker stats "$CONTAINER_NAME" --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}"

# --- Recent logs ---
log "Recent container logs (last 10 lines):"
docker logs "$CONTAINER_NAME" --tail 10

cat <<EOF

------------------------------------------------------------
LLM Service Test Results ✅

Service Status: Running
Health Check: ✅ Passed
Models API: ✅ Working
Chat Completion: ✅ Working
Response Time: ${response_time}s

Performance Notes:
- Response time should be < 10s for good performance
- Memory usage should be reasonable for your system
- Check logs above for any warnings

Test again: ./test_llm.sh
Stop service: ./teardown_llm.sh
------------------------------------------------------------
EOF