#!/usr/bin/env bash
# Поднимает только sentry для join-стека (Setup B), чтобы получить SENTRY_NODE_ID.
# Перед запуском задайте KEY_NAME, SEED_*, NODE_CONFIG, порты и остальное как для launch_add_network_node.sh
#
# Использование:
#   source ../path or export vars from launch.sh / вручную
#   ./bootstrap_join_sentry.sh
#   export SENTRY_NODE_ID=$(docker exec "${KEY_NAME}-sentry" inferenced tendermint show-node-id)
#   export USE_SENTRY=true
#   export P2P_EXTERNAL_ADDRESS="tcp://${KEY_NAME}-sentry:26656"   # или свой адрес
#   ./launch_add_network_node.sh

set -euo pipefail

if [ -f config.env ]; then
  # shellcheck source=/dev/null
  source config.env
fi

if [ -z "${KEY_NAME:-}" ]; then
  echo "KEY_NAME is required"
  exit 1
fi

COMPOSE_FILES="-f docker-compose-base.yml -f docker-compose.join.yml -f docker-compose.sentry.yml"
if [ "${PROXY_ACTIVE:-}" = "true" ]; then
  COMPOSE_FILES="$COMPOSE_FILES -f docker-compose.proxy.yml"
fi
if [ "${BRIDGE_ACTIVE:-}" = "true" ]; then
  COMPOSE_FILES="$COMPOSE_FILES -f docker-compose.bridge.yml"
fi

echo "Starting sentry only for project ${KEY_NAME}..."
docker compose -p "$KEY_NAME" $COMPOSE_FILES up sentry -d
echo "Wait for init, then:"
echo "  export SENTRY_NODE_ID=\$(docker exec \"${KEY_NAME}-sentry\" inferenced tendermint show-node-id)"
