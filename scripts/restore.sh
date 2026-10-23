#!/usr/bin/env bash
# Restores one collection from a completed backup. Usage: restore.sh <backup-dir> <collection>
# Each node's snapshot is uploaded to the node that produced it, with snapshot
# priority so empty replicas cannot overwrite restored data. The backup is fully
# validated BEFORE anything is deleted. An existing collection is replaced.
set -euo pipefail
. "$(dirname "$0")/_lib.sh"
dir=${1:?usage: restore.sh <backup-dir> <collection>}; c=${2:?usage: restore.sh <backup-dir> <collection>}
[ -d "$dir" ] && [[ $dir != *.partial* ]] || { echo "$dir is not a completed backup" >&2; exit 1; }

# 1. Validate: exactly one non-empty snapshot per node, before touching anything.
declare -A FILE
for node in "${NODES[@]}"; do
  files=("$dir/$node/$c/"*.snapshot)
  [ ${#files[@]} = 1 ] && [ -s "${files[0]}" ] || { echo "expected exactly one non-empty snapshot for $c on $node in $dir" >&2; exit 1; }
  FILE[$node]=${files[0]}
done

read -r -p "This replaces collection '$c' with the backup in $dir. Type yes: " a; [ "$a" = yes ]

# 2. Delete the existing collection. Only "not found" is acceptable as a failure.
code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 120 -X DELETE -H "api-key: $QDRANT_API_KEY" "$BASE/collections/$c?wait=true")
case $code in 200|404) ;; *) echo "deleting existing collection failed (HTTP $code); nothing restored" >&2; exit 1;; esac

# 3. Upload each node's snapshot to the node that made it.
for node in "${NODES[@]}"; do
  echo "restoring $c on $node from ${FILE[$node]}"
  curl -fsS --connect-timeout 5 --max-time 600 -X POST -H "api-key: $QDRANT_API_KEY" -F "snapshot=@${FILE[$node]}" \
    "http://127.0.0.1:$(node_port "$node")/collections/$c/snapshots/upload?priority=snapshot&wait=true" >/dev/null
done

# 4. Verify: every shard has 3 Active replicas.
echo "Checking replicas..."
wait_for "all replicas of $c active" 180 replicas_ok "$BASE" "$c" 3
q POST "$BASE/collections/$c/points/count" '{"exact":true}'; echo
