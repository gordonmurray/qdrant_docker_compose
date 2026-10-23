#!/usr/bin/env bash
# Rebuilds a node from scratch and puts its shards back. Usage: replace-node.sh <1|2|3>
# Removes the node's old peer from the cluster, deletes its volumes, starts it
# empty so it joins as a new peer, then re-replicates every shard it should hold.
set -euo pipefail
. "$(dirname "$0")/_lib.sh"
n=${1:?usage: replace-node.sh <1|2|3>}; node=qdrant-$n
read -r -p "Delete ALL data on $node and rebuild it from its peers? Type yes: " a; [ "$a" = yes ]

# Make sure the surviving nodes are running (the whole stack may be down, e.g.
# after node 1's volume was lost while stopped; `make up` cannot start then).
# --no-deps skips the wait on node 1. They rejoin from their own Raft state.
for m in 1 2 3; do
  [ "$m" != "$n" ] && docker compose up -d --no-deps --wait "qdrant-$m"
done
# Talk to a different, healthy node.
for m in 1 2 3; do [ "$m" != "$n" ] && { peer_url=http://127.0.0.1:$(node_port "qdrant-$m"); break; }; done
new_url=http://127.0.0.1:$(node_port "$node")
other=qdrant-$([ "$n" = 1 ] && echo 2 || echo 1)

old_id=$(q GET "$peer_url/cluster" | python3 -c "
import sys,json
for i,p in json.load(sys.stdin)['result']['peers'].items():
    if '$node:' in p['uri']: print(i)")

docker compose stop "$node"
if [ -n "$old_id" ]; then
  # Right after a leader stops there is an election; retry until the removal lands.
  wait_for "removal of old peer $old_id" 90 q DELETE "$peer_url/cluster/peer/$old_id?force=true"
  echo "removed old peer $old_id"
fi
docker compose rm -sf "$node" >/dev/null
# Remove storage and snapshots, but KEEP the founder marker volume (state): if this
# script is interrupted after the wipe, a plain restart of node 1 must still be
# refused. A failed removal aborts: restarting with old state would be wrong.
for v in storage snapshots; do
  if docker volume inspect "${PROJECT}_$node-$v" >/dev/null 2>&1; then
    docker volume rm "${PROJECT}_$node-$v" >/dev/null
  fi
done

# Node 1 normally refuses an empty start; give it a peer to join through.
if [ "$n" = 1 ]; then export QDRANT_1_BOOTSTRAP_URL=http://$other:6335; fi
docker compose up -d --no-deps --wait "$node"
unset QDRANT_1_BOOTSTRAP_URL

new_id=$(q GET "$new_url/cluster" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["peer_id"])')
echo "new peer id $new_id"

# Replicate each collection's shards that this node lacks, from a peer holding them.
export Q_TIMEOUT=900
names=$(list_collections "$peer_url")        # a failed listing aborts here
for c in $names; do
  info=$(q GET "$peer_url/collections/$c/cluster")
  rf=$(q GET "$peer_url/collections/$c" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["config"]["params"]["replication_factor"])')
  bodies=$(python3 - "$info" "$new_id" "$rf" <<'PY'
import sys, json
r = json.loads(sys.argv[1])["result"]; new = int(sys.argv[2]); rf = int(sys.argv[3])
holders = {}
for s in r["local_shards"]: holders.setdefault(s["shard_id"], []).append(r["peer_id"])
for s in r["remote_shards"]: holders.setdefault(s["shard_id"], []).append(s["peer_id"])
for sid, peers in sorted(holders.items()):
    if new not in peers and len(peers) < rf:
        print(json.dumps({"replicate_shard": {"shard_id": sid, "from_peer_id": peers[0], "to_peer_id": new}}))
PY
)
  while read -r body; do
    [ -n "$body" ] || continue
    echo "$c: $body"
    q POST "$peer_url/collections/$c/cluster?wait=true" "$body" >/dev/null
  done <<<"$bodies"
done

# Verify every collection is fully replicated (rf Active replicas per shard).
echo "Waiting for all replicas to become Active..."
for c in $names; do
  rf=$(q GET "$peer_url/collections/$c" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["config"]["params"]["replication_factor"])')
  wait_for "$c fully replicated ($rf per shard)" 600 replicas_ok "$peer_url" "$c" "$rf"
done
echo "$node replaced."
