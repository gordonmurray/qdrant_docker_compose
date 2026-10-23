#!/usr/bin/env bash
# Creates .env and the Prometheus key file with random secrets. Safe to re-run:
# it never overwrites an existing .env.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -f .env ]; then
  echo ".env already exists; leaving it alone."
else
  api=$(openssl rand -hex 32)
  ro=$(openssl rand -hex 32)
  pw=$(openssl rand -base64 18 | tr -d '/+=')
  sed -e "s|^QDRANT_API_KEY=.*|QDRANT_API_KEY=$api|" \
      -e "s|^QDRANT_READ_ONLY_API_KEY=.*|QDRANT_READ_ONLY_API_KEY=$ro|" \
      -e "s|^GRAFANA_ADMIN_PASSWORD=.*|GRAFANA_ADMIN_PASSWORD=$pw|" \
      .env.example > .env
  chmod 600 .env
  echo "Wrote .env with new keys."
fi

# Prometheus reads the read-only key from a file (a Docker secret).
umask 077
mkdir -p secrets
grep '^QDRANT_READ_ONLY_API_KEY=' .env | cut -d= -f2- | tr -d '\n' > secrets/qdrant_read_only_api_key
chmod 644 secrets/qdrant_read_only_api_key   # the container user must read it; the directory is not exported
echo "Wrote secrets/qdrant_read_only_api_key."
