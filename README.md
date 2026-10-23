# Qdrant on Docker Compose

A local, production-shaped Qdrant: a 3-node cluster behind HAProxy, with API-key
auth, health checks, resource limits, snapshots, Prometheus and Grafana.

| Service | URL (localhost only) | Notes |
|---|---|---|
| Qdrant (via HAProxy) | http://localhost:6333 (REST), `localhost:6334` (gRPC) | Web UI at `/dashboard` |
| Qdrant nodes direct | `:7001`, `:7002`, `:7003` | Inspect one node; also used by the scripts |
| HAProxy stats | http://localhost:8404 | Which nodes are healthy |
| Prometheus | http://localhost:9090 | Metrics and alert rules |
| Grafana | http://localhost:3000 | Dashboard "Qdrant Overview" |

## Start

```sh
make up        # creates .env with random keys on first run, then starts everything
make test      # end-to-end smoke test (REST, gRPC, auth, replication, metrics)
make seed      # 5000 sample points in "products": 384-d vectors, payload indexes
```

| Command | What it does |
|---|---|
| `make failover` | Stops a node, checks reads and writes still work, restarts it (~1 min) |
| `make reset-data` | Deletes all collections only; metrics and dashboards stay. Then `make seed` |
| `make snapshot` / `make restore b=backups/<ts> c=<name>` | Backup and restore |
| `make replace-node N=1` | Rebuild a node whose volume is lost |
| `make nuke` | Deletes everything, including volumes |

Ports are configurable in `.env` (see `.env.example`). To run a second copy next
to this one, set a different `COMPOSE_PROJECT_NAME` and a full set of ports.

Match `QDRANT_VERSION` and your client library version to what you run in
production, and bump them together.

Keys and the Grafana password are in `.env` (not committed). `QDRANT_API_KEY`
has full access; `QDRANT_READ_ONLY_API_KEY` can only read. Prometheus uses the
read-only key.

Requires Docker with Compose v2, and `curl`, `openssl`, `python3` on the host.

## Try it

```sh
set -a; . ./.env; set +a
H="api-key: $QDRANT_API_KEY"

curl -X PUT localhost:6333/collections/demo -H "$H" -H 'content-type: application/json' \
  -d '{"vectors":{"size":4,"distance":"Cosine"},"shard_number":3}'

curl -X PUT 'localhost:6333/collections/demo/points?wait=true' -H "$H" -H 'content-type: application/json' \
  -d '{"points":[{"id":1,"vector":[0.9,0.1,0.1,0.1],"payload":{"city":"Berlin"}},
                 {"id":2,"vector":[0.1,0.9,0.1,0.1],"payload":{"city":"Paris"}}]}'

curl -X POST localhost:6333/collections/demo/points/query -H "$H" -H 'content-type: application/json' \
  -d '{"query":[0.9,0.1,0.1,0.1],"limit":2,"with_payload":true}'

# Where do the shards live?
curl -s localhost:6333/collections/demo/cluster -H "$H" | python3 -m json.tool
```

Python: `pip install qdrant-client`, then
`QdrantClient(url="http://localhost:6333", api_key=...)`. Use the Web UI at
`/dashboard` (paste the API key when asked).

## Things to learn by doing

- **Replication**: new collections default to replication factor 3 and write
  consistency 2 (`.env`). Create one, then look at `/collections/<name>/cluster`.
- **Failure**: `docker compose stop qdrant-3`; reads and writes keep working
  through HAProxy (quorum is 2 of 3). Watch HAProxy stats and the Grafana
  "Nodes up" panel, and see `QdrantNodeDown` fire in Prometheus after 1 minute.
  Stop two nodes and writes fail: quorum is lost.
- **Rolling upgrade**: change `QDRANT_VERSION`, then
  `docker compose up -d --no-deps --wait qdrant-2`, check all replicas are
  `Active`, repeat for `qdrant-3`, then `qdrant-1`. (`--no-deps` stops Compose
  from recreating node 1 first.) Upgrade one minor version at a time.

## Backup and restore

`make snapshot` snapshots every collection on every node, copies each new file
to `./backups/<timestamp>/<node>/<collection>/`, then deletes it from the node so
snapshot volumes do not grow. The directory is named `*.partial` until every node
succeeded, so a failed run is never mistaken for a backup. It keeps the newest 7
(`BACKUP_KEEP`). Nodes are snapshotted one after another, so this is **not** a
point-in-time backup: stop writes first if you need that.

Restore one collection:

```sh
make restore b=backups/<timestamp> c=products
```

Each node's snapshot is uploaded to the node that produced it with snapshot
priority (so empty replicas cannot overwrite the data), then the script waits for
every replica to be `Active`. Tested: delete a collection, restore, and the point
count matches.

## Replacing a node

If a node loses its volume, rebuild it:

```sh
make replace-node N=3     # or 1 or 2
```

This removes the node's old peer from the cluster, wipes its volumes, starts it
empty so it joins as a new peer, copies every shard it should hold from a healthy
peer, and waits for all replicas to be `Active`. Joining a cluster does not copy
data by itself; the copy step is what restores replication.

Node 1 is the *founder*. If its storage is lost and it is simply restarted, it
would start a new, separate cluster. A marker on its own volume stops that: it
refuses to start and tells you to run `make replace-node N=1`. Nodes 2 and 3
need node 1 only for their first start; afterwards they rejoin from their own
state. If node 1's volume is lost while the stack is
stopped, `make up` cannot finish (node 1 refuses to start); run
`make replace-node N=1` directly, which starts nodes 2 and 3 first.

## Layout

```
compose.yaml            services, limits, healthchecks
config/production.yaml  Qdrant settings shared by all nodes
haproxy/                REST + gRPC load balancing, health-checked on /readyz
prometheus/             scrape config and alert rules
grafana/                provisioned datasource and dashboard
scripts/                init, test, failover, seed, snapshot/restore, replace-node
tools/                  Dockerfile for the Python client used by the gRPC check
```

## What this is and is not

It reproduces the *distributed behavior* of a production cluster: three peers,
sharding, replication 3 with write consistency 2, API keys, a health-checked
load balancer, REST and gRPC, and the same metrics and alerts. It does not
reproduce independent hosts, network partitions or production capacity: all
three nodes share one machine.

Known gaps and behaviors to be aware of:

- **No TLS.** Clients connect over plain HTTP and gRPC. If production uses TLS,
  your client TLS settings are untested here.
- **gRPC balancing is per connection.** HAProxy spreads connections, not requests,
  so one long-lived client channel talks to one node. Connections idle for more
  than 60s are closed by HAProxy; clients should reconnect.
- **Footprint.** Nodes are capped at 2 GB RAM and 2 CPUs each (`.env`), and the
  support services at 128-512 MB each. Measured on a laptop with the
  5000-point sample loaded: about 0.5 GB total resident and a ~30 s cold start;
  indexing a large collection uses much more.
- **Host metrics are opt-in.** `COMPOSE_PROFILES=host-metrics` adds node-exporter
  (read-only mount of `/`). On Docker Desktop it describes the Linux VM. The
  host panel and the host alerts are empty without it.
- **No Alertmanager.** Alerts show in Prometheus and Grafana but notify no one.
- **Backups stay on this machine** and are not point-in-time.
- Prometheus has no reload endpoint: after editing `prometheus/*.yml`, run
  `docker compose restart prometheus`.

Everything is bound to `127.0.0.1`. Do not change that without adding TLS.
