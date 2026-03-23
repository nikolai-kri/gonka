# Local test network (`local-test-net`)

This guide covers running the modular Docker Compose stack under `local-test-net/`, optional multi-participant topologies (including sentry), and how to run load or abuse-resilience tests against validator-facing endpoints. For file-level layout and environment variables, see also `local-test-net/README.md`.

## Prerequisites

- **Docker** and **Docker Compose** (v2 plugin).
- **Mock server image**: `mock-server` is built from `testermint/Dockerfile` and expects a pre-built JAR:
  ```bash
  cd testermint/mock_server
  ./gradlew shadowJar
  ```
  If the host has no JDK, build inside a container from the **repository root**:
  ```bash
  docker run --rm -v "$(pwd)/testermint:/work" -w /work/mock_server \
    eclipse-temurin:21-jdk bash -c "chmod +x ./gradlew && ./gradlew shadowJar"
  ```

## Image tags

Compose files under `local-test-net` pin chain/API images to the same tags as production examples (e.g. `ghcr.io/product-science/inferenced:0.2.10-post4`, `ghcr.io/product-science/api:0.2.10-post4`). If you change versions, align them with `deploy/join/docker-compose.yml` or your release notes.

## Quick start: single genesis node

From `local-test-net/`:

```bash
export REST_API_ACTIVE=true PUBLIC_SERVER_PORT=9000 ML_SERVER_PORT=9001 ADMIN_SERVER_PORT=9002 \
  ML_GRPC_SERVER_PORT=9003 NATS_SERVER_PORT=9004 KEY_NAME=genesis \
  NODE_CONFIG=node_payload_mock_server_genesis.json \
  PUBLIC_URL="http://genesis-api:9000" POC_CALLBACK_URL="http://genesis-api:9100" \
  WIREMOCK_PORT=8090
mkdir -p "./prod-local/wiremock/genesis/mappings/" "./prod-local/wiremock/genesis/__files/"
cp ../testermint/src/main/resources/mappings/*.json "./prod-local/wiremock/genesis/mappings/"
sed 's/{{KEY_NAME}}/genesis/g' ../testermint/src/main/resources/alternative-mappings/validate_poc_batch.template.json \
  > "./prod-local/wiremock/genesis/mappings/validate_poc_batch.json"
docker compose -p genesis -f docker-compose-base.yml -f docker-compose.genesis.yml -f docker-compose-node-p2p.yml up -d --build
```

**Port conflicts**: if something else already binds the default Tendermint RPC port (`26657`), set `RPC_PORT` and `P2P_PORT` (e.g. `RPC_PORT=26667` `P2P_PORT=27656`) before `up`.

Smoke checks:

```bash
curl -s http://127.0.0.1:9000/v1/status
curl -s "http://127.0.0.1:${RPC_PORT:-26657}/status"
```

## Multi-participant topology (genesis + sentry join + P2P join)

The script `local-test-net/launch_three_participants.sh` brings up:

1. **Genesis** — base + genesis + host P2P (`docker-compose-node-p2p.yml`).
2. **Join2 (sentry / Setup B)** — `bootstrap_join_sentry.sh` then `launch_add_network_node.sh` with `USE_SENTRY=true` after `SENTRY_NODE_ID` is known.
3. **Join3 (standard P2P / Setup A)** — `launch_add_network_node.sh` with `docker-compose-node-p2p.yml`.

```bash
cd local-test-net
./launch_three_participants.sh
```

Stop and remove data:

```bash
./launch_three_participants.sh down
```

Default ports (adjust if they clash on the host):

| Role   | DAPI (public HTTP) | Tendermint RPC (host) | P2P (host) | Notes        |
|--------|--------------------|------------------------|------------|--------------|
| Genesis | 9000              | 26667 (if overridden)  | 27656      | seed for joins |
| Join2 (sentry) | 9010       | 8101 (validator RPC)   | —          | sentry P2P/RPC: 18211 / 18311 by default |
| Join3  | 9030              | 8103                   | 8203       |              |

## Join stacks and the Docker network

Join projects attach to the **existing** bridge `chain-public` created by genesis. Compose merges include:

- `docker-compose.chain-public-external.yml` — declares `chain-public` as **external** so join stacks reuse the same network.

**Order**: start **genesis first**, then join nodes. Starting a join project before `chain-public` exists will fail.

## Sentry service data directory

The sentry container uses the same init path as a normal node image: default home `/root/.inference`. The sentry service therefore mounts:

`./prod-local/${KEY_NAME}-sentry` → `/root/.inference`  
and sets `STATE_DIR=/root/.inference`

so `init-docker.sh` in the image writes keys and config where the binary expects them. The validator behind sentry remains a separate service with its own volume under `./prod-local/${KEY_NAME}`.

## Scripts reference

| Script | Purpose |
|--------|---------|
| `launch.sh` | Genesis + two join nodes (standard P2P). |
| `launch_add_network_node.sh` | Single join stack; respects `USE_SENTRY`, optional proxy/bridge. |
| `bootstrap_join_sentry.sh` | Sentry-only bootstrap to read `SENTRY_NODE_ID`. |
| `launch_three_participants.sh` | Genesis + sentry join + P2P join (orchestrated). |
| `abuse-validator-smoke.sh` | Coarse parallel `curl` load against DAPI `/v1/status` and JSON-RPC `status` (see below). |

---

# Load testing and validator stress scenarios

Use these **only on networks you own** (e.g. local Docker hosts or isolated testnets).

## Official tooling: `compressa-perf`

The repository documents stress testing with a fork of **compressa-perf** (see root `CONTRIBUTING.md`, section *Stress Testing*).

**Install** (use a **venv** on Debian/Ubuntu — system Python may block `pip install` with `externally-managed-environment` / PEP 668):

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install git+https://github.com/product-science/compressa-perf.git
```

Alternatively: `pipx install git+https://github.com/product-science/compressa-perf.git`.

The CLI uses **kebab-case** flags (e.g. `--node-url`, `--model-name`). Older docs may show underscores; run `compressa-perf measure --help` for your version.

**`measure`** — finite experiment (throughput/latency under a defined workload). **`stress`** — long-running load (see `compressa-perf stress --help`).

For `local-test-net`, point `--node-url` at the **DAPI** HTTP entry on the host (trailing slash as in tool examples):

| Stack   | Example `--node-url`        |
|---------|-----------------------------|
| Genesis | `http://127.0.0.1:9000/`    |
| Join2 (sentry) | `http://127.0.0.1:9010/` |
| Join3 (P2P)    | `http://127.0.0.1:9030/` |

From another machine, replace `127.0.0.1` with the host’s LAN IP.

**Minimal `measure` example** (after `local-test-net` is up and `curl http://127.0.0.1:9000/v1/status` works):

```bash
compressa-perf measure \
  --node-url http://127.0.0.1:9000/ \
  --model-name Qwen/Qwen2.5-7B-Instruct \
  --experiment-name "local-test-net-smoke" \
  --create-account-testnet \
  --inferenced-path /path/to/inferenced \
  --generate-prompts \
  --num-tasks 10 \
  --num-runners 2
```

Build `inferenced` from this repo (`inference-chain`) or pass an absolute path to the binary. If your CLI does not require `--inferenced-path`, omit it.

**List experiments and metrics:**

```bash
compressa-perf list --show-metrics --show-parameters
```

Use the **same flags** across runs and only change `--node-url` to compare **genesis vs sentry join vs P2P join** under identical load.

## Smoke script in `local-test-net`

`abuse-validator-smoke.sh` runs sequential high-volume `curl` loops (not a full HTTP benchmark) against:

- `GET /v1/status` on each configured DAPI base URL.
- JSON-RPC `status` on each configured Tendermint RPC URL.

For **each** URL, requests run **one after another**; **different** URLs are exercised **in parallel** (background jobs). The total number of requests per URL is `TOTAL_REQUESTS_PER_TARGET` (default **2000** in `abuse-validator-smoke.sh`; override as needed).

```bash
cd local-test-net
./abuse-validator-smoke.sh both
```

Override targets and request count:

```bash
DAPI_URLS="http://127.0.0.1:9000 http://127.0.0.1:9010 http://127.0.0.1:9030" \
RPC_URLS="http://127.0.0.1:26667 http://127.0.0.1:8101 http://127.0.0.1:8103" \
TOTAL_REQUESTS_PER_TARGET=500 \
./abuse-validator-smoke.sh both
```

For heavier or more realistic profiles, use **k6**, **vegeta**, **hey**, or similar against the same URLs.

## What to compare

- **HTTP**: latency and error rates on DAPI; CPU/memory on `*-api` containers (`docker stats`).
- **Chain**: Tendermint RPC latency, block height progression, `catching_up` in `/status`.
- **Topology**: with **sentry**, external P2P pressure hits the sentry first; the validator node is reached via `persistent_peers` to the sentry. With **direct P2P**, the validator’s P2P port is exposed according to compose.

## Relevant protections (DAPI)

The decentralized API applies limits and validation (non-exhaustive): body size caps on chat requests, bandwidth / inference limits (`BandwidthLimiter`), rate limiting on `POST /v1/poc/proofs`, transaction queue handling for mempool-related errors. Use stress tests to observe **where** saturation occurs (API vs RPC vs chain), not to assume absence of limits.

## Running tests from another machine

Ports are published on the host’s interfaces (default Docker bind `0.0.0.0`). From a second host on the same network:

```bash
curl -s "http://<host-ip>:9000/v1/status"
```

Ensure host firewalls and cloud security groups allow the chosen ports. **Do not** expose `local-test-net` (test mode, permissive settings) to the public internet without additional hardening.

## Related paths

- `local-test-net/README.md` — modular compose files, sentry vs P2P, DNS add-ons.
- `CONTRIBUTING.md` — `compressa-perf` install and examples.
- `test-net-cloud/compressa-testing/compressa-how-to.sh` — additional `compressa-perf` examples.
- `testermint/README.md` — integration tests that drive multi-node behaviour.
