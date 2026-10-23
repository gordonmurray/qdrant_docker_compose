#!/usr/bin/env bash
# Snapshots every collection's local shards on every node, copies each file to
# ./backups/<timestamp>/<node>/<collection>/, then deletes it from the node.
# The directory is named *.partial until every node succeeded, so a failed run is
# never mistaken for a backup. Nodes are snapshotted one after another, so this is
# NOT a point-in-time backup: stop writes first if you need consistency.
set -euo pipefail
. "$(dirname "$0")/_lib.sh"

KEEP=${BACKUP_KEEP:-7}
ts=$(date -u +%Y%m%dT%H%M%SZ)
dest="backups/$ts"
mkdir -p "$dest.partial"

export Q_TIMEOUT=600   # snapshots of big collections take a while
for node in "${NODES[@]}"; do
  url=http://127.0.0.1:$(node_port "$node")
  cid=$(docker compose ps -q "$node")
  names=$(list_collections "$url")   # a failed listing aborts the backup
  for c in $names; do
    echo "snapshot $node/$c"
    name=$(q POST "$url/collections/$c/snapshots?wait=true" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["name"])')
    mkdir -p "$dest.partial/$node/$c"
    docker cp "$cid:/qdrant/snapshots/$c/$name" "$dest.partial/$node/$c/$name"
    [ -s "$dest.partial/$node/$c/$name" ] || { echo "copy of $name failed" >&2; exit 1; }
    q DELETE "$url/collections/$c/snapshots/$name?wait=true" >/dev/null
  done
done

mv "$dest.partial" "$dest"
# Keep the newest $KEEP completed backups (and clear old partial ones).
ls -1d backups/*/ 2>/dev/null | grep -v '\.partial/$' | sort -r | tail -n +$((KEEP + 1)) | xargs -r rm -rf
echo "Backup written to $dest"
