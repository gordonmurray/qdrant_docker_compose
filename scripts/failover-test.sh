#!/usr/bin/env bash
# Stops one node and checks the cluster keeps serving reads and writes through
# HAProxy, then brings it back and waits for every replica to be Active again.
# Takes about a minute. Restores the node even if a check fails. Every assertion
# exits non-zero on failure.
set -euo pipefail
. "$(dirname "$0")/_lib.sh"

VICTIM=${1:-qdrant-3}
COL="failover_$(date +%s)_$$"
cleanup() { docker compose start "$VICTIM" >/dev/null 2>&1 || true; q DELETE "$BASE/collections/$COL" >/dev/null 2>&1 || true; }
trap cleanup EXIT
ok() { echo "  ok   $*"; }
fail() { echo "  FAIL $*" >&2; exit 1; }
count() { q POST "$BASE/collections/$COL/points/count" '{"exact":true}' | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["count"])'; }

q PUT "$BASE/collections/$COL?wait=true" '{"vectors":{"size":4,"distance":"Cosine"},"shard_number":3}' >/dev/null
wait_for "all replicas Active before the test" 60 replicas_ok "$BASE" "$COL" 3 || fail "replicas not Active before the test"
q PUT "$BASE/collections/$COL/points?wait=true" '{"points":[{"id":1,"vector":[1,0,0,0]}]}' >/dev/null || fail "initial write"

echo "Stopping $VICTIM"
docker compose stop "$VICTIM" >/dev/null
# HAProxy needs 3 failed checks to drop the node; retry until traffic is clean.
wait_for "write with one node down" 60 q PUT "$BASE/collections/$COL/points?wait=true" '{"points":[{"id":2,"vector":[0,1,0,0]}]}' \
  || fail "write failed with $VICTIM down (quorum is 2 of 3)"
ok "write succeeded with $VICTIM down"
[ "$(count)" = 2 ] || fail "read after write returned $(count) points, expected 2"
ok "read returned both points"

echo "Starting $VICTIM"
docker compose start "$VICTIM" >/dev/null
wait_for "$VICTIM healthy" 120 bash -c "[ \"\$(docker inspect -f '{{.State.Health.Status}}' \$(docker compose ps -q $VICTIM))\" = healthy ]" \
  || fail "$VICTIM did not become healthy"
wait_for "replicas Active again" 120 replicas_ok "$BASE" "$COL" 3 || fail "replicas not Active after $VICTIM returned"
[ "$(count)" = 2 ] || fail "after rejoin count is $(count), expected 2"
ok "$VICTIM rejoined; both points present, all replicas Active"
echo "Failover test passed."
