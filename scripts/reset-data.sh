#!/usr/bin/env bash
# Deletes every collection (data only). Containers, Prometheus and Grafana keep
# their state. Use `make nuke` to delete the volumes too.
set -euo pipefail
. "$(dirname "$0")/_lib.sh"
names=$(list_collections "$BASE")
for c in $names; do
  echo "deleting $c"
  q DELETE "$BASE/collections/$c?wait=true" >/dev/null
done
