#!/usr/bin/env bash
# local-test-net only — your own machine.
# Same-pattern load against DAPI + Tendermint RPC to compare stack behaviour.
#
# Examples:
#   ./abuse-validator-smoke.sh dapi
#   ./abuse-validator-smoke.sh rpc
#   ./abuse-validator-smoke.sh both
#
# Override targets:
#   DAPI_URLS="http://127.0.0.1:9000 http://127.0.0.1:9010 http://127.0.0.1:9030" \
#   RPC_URLS="http://127.0.0.1:26667 http://127.0.0.1:8101 http://127.0.0.1:8103" \
#   TOTAL_REQUESTS_PER_TARGET=500 \
#   ./abuse-validator-smoke.sh both
#
# Behaviour: per URL, a sequential loop of N curl requests (no parallelism within one URL).
# Different base URLs in DAPI_URLS / RPC_URLS run in parallel (background jobs).
set -euo pipefail

DAPI_URLS=${DAPI_URLS:-"http://127.0.0.1:9000 http://127.0.0.1:9010 http://127.0.0.1:9030"}
RPC_URLS=${RPC_URLS:-"http://127.0.0.1:26667 http://127.0.0.1:8101 http://127.0.0.1:8103"}

# Sequential HTTP requests per endpoint (per base URL).
TOTAL_REQUESTS_PER_TARGET=${TOTAL_REQUESTS_PER_TARGET:-2000}
MODE=${1:-both}

log() { echo "[$(date -Iseconds)] $*"; }

# Rough metrics: ok/fail counts and wall time (not a proper HTTP benchmark)
run_curl_flood() {
  local name=$1
  local url=$2
  local path=$3
  local full="${url}${path}"
  local ok=0 fail=0
  local start end
  start=$(date +%s%3N)
  for _ in $(seq 1 "$TOTAL_REQUESTS_PER_TARGET"); do
    if curl -sf -o /dev/null -m 3 "$full"; then
      ok=$((ok + 1))
    else
      fail=$((fail + 1))
    fi
  done
  end=$(date +%s%3N)
  local ms=$((end - start))
  if [ "$ms" -eq 0 ]; then ms=1; fi
  log "$name $full  ok=$ok fail=$fail duration_ms=$ms (~$((ok * 1000 / ms)) req/s rough)"
}

dapi_load() {
  log "=== DAPI GET /v1/status (${TOTAL_REQUESTS_PER_TARGET} sequential requests per base URL; URLs in parallel) ==="
  for base in $DAPI_URLS; do
    run_curl_flood "dapi-status" "$base" "/v1/status" &
  done
  wait
}

rpc_load() {
  log "=== Tendermint RPC POST / (JSON-RPC status; ${TOTAL_REQUESTS_PER_TARGET} sequential requests per RPC URL; URLs in parallel) ==="
  local body='{"jsonrpc":"2.0","id":1,"method":"status","params":[]}'
  for base in $RPC_URLS; do
    (
      ok=0 fail=0
      start=$(date +%s%3N)
      for _ in $(seq 1 "$TOTAL_REQUESTS_PER_TARGET"); do
        if curl -sf -o /dev/null -m 3 -X POST "$base" -H 'Content-Type: application/json' -d "$body"; then
          ok=$((ok + 1))
        else
          fail=$((fail + 1))
        fi
      done
      end=$(date +%s%3N)
      log "rpc-status $base ok=$ok fail=$fail duration_ms=$((end - start))"
    ) &
  done
  wait
}

case "$MODE" in
  dapi) dapi_load ;;
  rpc) rpc_load ;;
  both) dapi_load; rpc_load ;;
  *)
    echo "Usage: $0 [dapi|rpc|both]"
    exit 1
    ;;
esac

log "Done. Check docker stats and logs: docker logs <container> --tail 200"
log "POST /v1/poc/proofs is rate-limited in DAPI; GET /v1/status is not (see decentralized-api/internal/server/public/server.go)."
