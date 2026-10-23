#!/usr/bin/env bash
# Starts one Qdrant node. Inputs (environment): NODE (qdrant-1..3), FOUNDER=1 for
# the node allowed to create a brand-new cluster, BOOTSTRAP_URL to join through.
#
# Guard for the founder: once it has been up with Raft state, a marker is kept on
# a separate volume. If the marker exists but the storage is empty, the volume was
# lost; starting without BOOTSTRAP_URL would create a second, separate cluster, so
# refuse. Use `make replace-node N=1` to rebuild it.
set -euo pipefail

STATE=/qdrant/storage/raft_state.json
MARKER=/qdrant/cluster-state/initialized
ARGS=(--uri "http://${NODE}:6335")

if [ -n "${BOOTSTRAP_URL:-}" ]; then
  ARGS+=(--bootstrap "$BOOTSTRAP_URL")
elif [ "${FOUNDER:-0}" != 1 ]; then
  echo "$NODE: not the founder and BOOTSTRAP_URL is empty; refusing to start." >&2
  exit 1
elif [ ! -f "$STATE" ] && [ -f "$MARKER" ]; then
  echo "$NODE: storage is empty but this cluster was initialised before." >&2
  echo "Starting now would create a second cluster. Run: make replace-node N=1" >&2
  echo "(it starts the surviving nodes itself, so this works with the stack down)" >&2
  exit 1
fi

if [ -d "$(dirname "$MARKER")" ]; then
  ( until [ -f "$STATE" ]; do sleep 2; done; touch "$MARKER" ) &
fi

exec ./qdrant "${ARGS[@]}"
