#!/usr/bin/env bash
# End-to-end check: auth, cluster health, effective collection settings, write,
# search over REST and gRPC, read-only key, Prometheus scrape, Grafana.
set -euo pipefail
. "$(dirname "$0")/_lib.sh"

COL="smoke_$(date +%s)_$$"
cleanup() { q DELETE "$BASE/collections/$COL" >/dev/null 2>&1 || true; }
trap cleanup EXIT
ok() { echo "  ok   $*"; }
fail() { echo "  FAIL $*" >&2; exit 1; }
py() { python3 -c "$1"; }

echo "Qdrant"
code=$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' "$BASE/collections")
case $code in 401|403) ok "request without a key is rejected ($code)";; *) fail "unauthenticated request returned $code";; esac

wait_for "3 cluster peers" 60 bash -c ". scripts/_lib.sh; q GET $BASE/cluster | python3 -c 'import sys,json; sys.exit(0 if len(json.load(sys.stdin)[\"result\"][\"peers\"])==3 else 1)'" \
  && ok "cluster has 3 peers" || fail "cluster does not have 3 peers"

q PUT "$BASE/collections/$COL?wait=true" '{"vectors":{"size":4,"distance":"Cosine"},"shard_number":3}' >/dev/null
read -r rf wcf < <(q GET "$BASE/collections/$COL" | py 'import sys,json; p=json.load(sys.stdin)["result"]["config"]["params"]; print(p["replication_factor"], p["write_consistency_factor"])')
[ "$rf/$wcf" = "${QDRANT_DEFAULT_REPLICATION_FACTOR:-3}/${QDRANT_DEFAULT_WRITE_CONSISTENCY_FACTOR:-2}" ] \
  && ok "collection got replication $rf, write consistency $wcf from defaults" || fail "collection settings $rf/$wcf"

wait_for "replicas active" 60 bash -c ". scripts/_lib.sh; q GET $BASE/collections/$COL/cluster | python3 -c '
import sys,json
r=json.load(sys.stdin)[\"result\"]
s=r[\"local_shards\"]+r[\"remote_shards\"]
sys.exit(0 if len(s)==9 and all(x[\"state\"]==\"Active\" for x in s) else 1)'" \
  && ok "all 9 shard replicas (3 shards x 3) are Active" || fail "replicas not all Active"

q PUT "$BASE/collections/$COL/points?wait=true" '{"points":[
  {"id":1,"vector":[0.9,0.1,0.1,0.1],"payload":{"name":"a"}},
  {"id":2,"vector":[0.1,0.9,0.1,0.1],"payload":{"name":"b"}},
  {"id":3,"vector":[0.1,0.1,0.9,0.1],"payload":{"name":"c"}}]}' >/dev/null && ok "wrote 3 points"
top=$(q POST "$BASE/collections/$COL/points/query" '{"query":[0.9,0.1,0.1,0.1],"limit":1,"with_payload":true}' | py 'import sys,json; print(json.load(sys.stdin)["result"]["points"][0]["payload"]["name"])')
[ "$top" = a ] && ok "REST search returned the nearest point" || fail "search returned $top"

code=$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -H "api-key: $QDRANT_READ_ONLY_API_KEY" -H 'content-type: application/json' -X PUT "$BASE/collections/$COL/points" -d '{"points":[]}')
[ "$code" = 403 ] && ok "read-only key cannot write" || fail "read-only key write returned $code"

echo "gRPC"
img=$(tools_image)
docker run --rm --network "${PROJECT}_backend" -e HOST=haproxy -e PORT=6334 -e COLLECTION="$COL" -e KEY="$QDRANT_API_KEY" \
  -v "$PWD/scripts/grpc_check.py:/work/grpc_check.py:ro" "$img" python grpc_check.py | sed 's/^/  ok   /' || fail "gRPC check"

echo "Prometheus"
wait_for "3 Qdrant targets up" 90 bash -c "curl -fsS --connect-timeout 5 --max-time 10 -G http://127.0.0.1:$PROM_PORT/api/v1/query --data-urlencode 'query=count(up{job=\"qdrant\"}==1)==3' | grep -q '\"value\"'" \
  && ok "3 Qdrant targets up" || fail "fewer than 3 Qdrant targets up"
wait_for "HAProxy target up" 60 bash -c "curl -fsS --connect-timeout 5 --max-time 10 -G http://127.0.0.1:$PROM_PORT/api/v1/query --data-urlencode 'query=up{job=\"haproxy\"}==1' | grep -q '\"value\"'" \
  && ok "HAProxy target up" || fail "HAProxy target down"

echo "Grafana"
curl -fsS --connect-timeout 5 --max-time 10 "http://127.0.0.1:$GRAFANA_PORT/api/health" >/dev/null && ok "healthy"
echo "All checks passed."
