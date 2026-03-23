#!/usr/bin/env bash
# Три участника: genesis (P2P на хост), join2 через sentry (Setup B), join3 с P2P валидатора на хост (Setup A).
# Требования: Docker; JAR mock-server: из testermint/mock_server выполнить ./gradlew shadowJar (или см. README).
#
# Порты по умолчанию подстроены под отдельный genesis RPC (26667), если на хосте занят 127.0.0.1:26657 (sentry и т.п.).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

down_all() {
  docker compose -p genesis -f docker-compose-base.yml -f docker-compose.genesis.yml -f docker-compose-node-p2p.yml down 2>/dev/null || true
  docker compose -p join2 -f docker-compose-base.yml -f docker-compose.chain-public-external.yml -f docker-compose.join.yml -f docker-compose.sentry.yml down 2>/dev/null || true
  docker compose -p join2 -f docker-compose-base.yml -f docker-compose.chain-public-external.yml -f docker-compose.join.yml -f docker-compose-node-p2p.yml down 2>/dev/null || true
  docker compose -p join3 -f docker-compose-base.yml -f docker-compose.chain-public-external.yml -f docker-compose.join.yml -f docker-compose-node-p2p.yml down 2>/dev/null || true
}

if [ "${1:-}" = "down" ]; then
  down_all
  docker run --rm -v "$(pwd):/workdir" -w /workdir alpine:3.19 rm -rf prod-local 2>/dev/null || true
  echo "Stopped stacks (genesis, join2, join3) and removed prod-local."
  exit 0
fi

down_all
docker run --rm -v "$(pwd):/workdir" -w /workdir alpine:3.19 rm -rf prod-local 2>/dev/null || true

# --- Genesis (Setup A + genesis) ---
export REST_API_ACTIVE=true
export PUBLIC_SERVER_PORT=9000
export ML_SERVER_PORT=9001
export ADMIN_SERVER_PORT=9002
export ML_GRPC_SERVER_PORT=9003
export NATS_SERVER_PORT=9004
export KEY_NAME=genesis
export NODE_CONFIG="node_payload_mock_server_${KEY_NAME}.json"
export PUBLIC_URL="http://${KEY_NAME}-api:9000"
export POC_CALLBACK_URL="http://${KEY_NAME}-api:9100"
export IS_GENESIS=true
export WIREMOCK_PORT=8090
export RPC_PORT="${GENESIS_RPC_PORT:-26667}"
export P2P_PORT="${GENESIS_P2P_PORT:-27656}"

mkdir -p "./prod-local/wiremock/$KEY_NAME/mappings/" "./prod-local/wiremock/$KEY_NAME/__files/"
cp ../testermint/src/main/resources/mappings/*.json "./prod-local/wiremock/$KEY_NAME/mappings/"
sed "s/{{KEY_NAME}}/$KEY_NAME/g" ../testermint/src/main/resources/alternative-mappings/validate_poc_batch.template.json > "./prod-local/wiremock/$KEY_NAME/mappings/validate_poc_batch.json"
if [ -n "$(ls -A ./public-html 2>/dev/null)" ]; then
  cp -r ../public-html/* "./prod-local/wiremock/$KEY_NAME/__files/"
fi

echo "Starting genesis (RPC host ${RPC_PORT}, P2P host ${P2P_PORT})..."
docker compose -p genesis \
  -f docker-compose-base.yml \
  -f docker-compose.genesis.yml \
  -f docker-compose-node-p2p.yml \
  up -d --build

echo "Waiting for genesis RPC..."
for _ in $(seq 1 60); do
  if curl -sf "http://127.0.0.1:${RPC_PORT}/status" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
if ! curl -sf "http://127.0.0.1:${RPC_PORT}/status" >/dev/null; then
  echo "Genesis RPC not ready on ${RPC_PORT}"
  exit 1
fi
sleep 10

# Общие параметры для join-нод
export SEED_API_URL="http://genesis-api:9000"
export SEED_NODE_RPC_URL="http://genesis-node:26657"
export SEED_NODE_P2P_URL="http://genesis-node:26656"
export IS_GENESIS=false
export SYNC_WITH_SNAPSHOTS=false

# --- join2: sentry (Setup B) ---
export KEY_NAME=join2
export NODE_CONFIG="node_payload_mock_server_${KEY_NAME}.json"
export PUBLIC_IP="join2-api"
export PUBLIC_SERVER_PORT=9010
export ML_SERVER_PORT=9011
export ADMIN_SERVER_PORT=9012
export ML_GRPC_SERVER_PORT=9013
export NATS_SERVER_PORT=9014
export WIREMOCK_PORT=8091
export RPC_PORT=8101
export SENTRY_HOST_P2P_PORT="${SENTRY_HOST_P2P_PORT:-18211}"
export SENTRY_HOST_RPC_PORT="${SENTRY_HOST_RPC_PORT:-18311}"
export PUBLIC_URL="http://${KEY_NAME}-api:9010"
export POC_CALLBACK_URL="http://${KEY_NAME}-api:9100"
export P2P_EXTERNAL_ADDRESS="tcp://${KEY_NAME}-sentry:26656"

unset USE_SENTRY || true
unset SENTRY_NODE_ID || true

echo "Bootstrapping join2 sentry only..."
./bootstrap_join_sentry.sh

echo "Waiting for sentry to initialize..."
sleep 25
SENTRY_NODE_ID="$(docker exec "${KEY_NAME}-sentry" inferenced tendermint show-node-id)"
export SENTRY_NODE_ID
echo "SENTRY_NODE_ID=${SENTRY_NODE_ID}"

export USE_SENTRY=true
echo "Starting join2 full stack (sentry + validator + api + mock)..."
./launch_add_network_node.sh

unset USE_SENTRY || true
unset SENTRY_NODE_ID || true

# --- join3: P2P на хост (Setup A) ---
export KEY_NAME=join3
export NODE_CONFIG="node_payload_mock_server_${KEY_NAME}.json"
export PUBLIC_IP="join3-api"
export PUBLIC_SERVER_PORT=9030
export ML_SERVER_PORT=9031
export ADMIN_SERVER_PORT=9032
export ML_GRPC_SERVER_PORT=9033
export NATS_SERVER_PORT=9034
export WIREMOCK_PORT=8093
export RPC_PORT=8103
export P2P_PORT=8203
export PUBLIC_URL="http://${KEY_NAME}-api:9030"
export POC_CALLBACK_URL="http://${KEY_NAME}-api:9100"
export P2P_EXTERNAL_ADDRESS="http://${KEY_NAME}-node:26656"

echo "Starting join3 (host P2P ${P2P_PORT})..."
./launch_add_network_node.sh

echo "Done."
echo "Genesis API:     http://127.0.0.1:9000/v1/status"
echo "Join2 (sentry):  API http://127.0.0.1:9010/v1/status  sentry P2P host ${SENTRY_HOST_P2P_PORT:-18211}"
echo "Join3 (P2P):     API http://127.0.0.1:9030/v1/status  node P2P host ${P2P_PORT:-8203}"
echo "Participants:    curl -s http://127.0.0.1:9000/v1/participants"
