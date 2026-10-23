# Shared helpers. Source this file; do not run it.
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[ -f .env ] || { echo "No .env. Run: make init" >&2; exit 1; }
set -a; . ./.env; set +a
PROJECT=${COMPOSE_PROJECT_NAME:-qdrant}
REST_PORT=${QDRANT_REST_PORT:-6333}
GRPC_PORT=${QDRANT_GRPC_PORT:-6334}
PROM_PORT=${PROMETHEUS_PORT:-9090}
GRAFANA_PORT=${GRAFANA_PORT:-3000}
NODE_PORT_1=${QDRANT_NODE_PORT_1:-7001}
NODE_PORT_2=${QDRANT_NODE_PORT_2:-7002}
NODE_PORT_3=${QDRANT_NODE_PORT_3:-7003}
NODES=(qdrant-1 qdrant-2 qdrant-3)
BASE=http://127.0.0.1:$REST_PORT

node_port() { local v="NODE_PORT_${1##*-}"; echo "${!v}"; }

# q METHOD URL [json-body]   authenticated call with the full-access key.
# Every call has a connect timeout and an overall timeout (Q_TIMEOUT, seconds;
# raise it for snapshot and replication calls).
q() {
  local m=$1 u=$2; shift 2
  local common=(-fsS --connect-timeout 5 --max-time "${Q_TIMEOUT:-30}" -X "$m" -H "api-key: $QDRANT_API_KEY")
  if [ $# -gt 0 ]; then
    curl "${common[@]}" -H 'content-type: application/json' -d "$1" "$u"
  else
    curl "${common[@]}" "$u"
  fi
}

# list_collections BASE_URL   prints one collection name per line. Fails (non-zero)
# if the listing call or its parsing fails, so callers cannot mistake an error for
# "no collections". Use it in a checked assignment: names=$(list_collections "$url")
list_collections() {
  q GET "$1/collections" | python3 -c 'import sys,json; print("\n".join(c["name"] for c in json.load(sys.stdin)["result"]["collections"]))'
}

# replicas_ok BASE_URL COLLECTION EXPECTED_PER_SHARD   exit 0 only if every shard
# has exactly EXPECTED Active replicas and no replica is in another state.
replicas_ok() {
  q GET "$1/collections/$2/cluster" | python3 -c '
import sys, json, collections
r = json.load(sys.stdin)["result"]; want = int(sys.argv[1])
n = collections.Counter(); bad = 0
for s in r["local_shards"] + r["remote_shards"]:
    if s["state"] == "Active": n[s["shard_id"]] += 1
    else: bad += 1
sys.exit(0 if n and not bad and all(v == want for v in n.values()) else 1)' "$3"
}

# wait_for "description" seconds command...   poll until the command succeeds.
wait_for() {
  local what=$1 secs=$2; shift 2
  local end=$((SECONDS + secs))
  # Each attempt is bounded by the curl timeouts in q(); the deadline is checked
  # between attempts, so a wait can overrun by at most one Q_TIMEOUT.
  until "$@" >/dev/null 2>&1; do
    [ $SECONDS -lt $end ] || { echo "Timed out waiting for: $what" >&2; return 1; }
    sleep 2
  done
}

# Python client image, built once, for gRPC checks and anything else needing it.
tools_image() {
  docker image inspect qdrant-local-tools >/dev/null 2>&1 || docker build -q -t qdrant-local-tools tools >/dev/null
  echo qdrant-local-tools
}
