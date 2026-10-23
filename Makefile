.PHONY: init up down restart ps logs status test failover seed reset-data snapshot restore replace-node nuke
SHELL := /bin/bash
init:      ## Generate .env and secrets (once)
	@./scripts/init.sh
up: init   ## Start everything
	docker compose up -d --wait
	@. ./.env; echo; echo "Qdrant     http://localhost:$${QDRANT_REST_PORT:-6333}/dashboard"; echo "Grafana    http://localhost:$${GRAFANA_PORT:-3000}"; echo "Prometheus http://localhost:$${PROMETHEUS_PORT:-9090}"
down:      ## Stop; data is kept
	docker compose down
restart:
	docker compose restart
ps:
	docker compose ps
logs:      ## Follow logs: make logs s=qdrant-1
	docker compose logs -f --tail=100 $(s)
status:    ## Cluster view from the API
	@. ./.env; curl -fsS --connect-timeout 5 --max-time 10 -H "api-key: $$QDRANT_API_KEY" localhost:$${QDRANT_REST_PORT:-6333}/cluster | python3 -m json.tool
test:      ## End-to-end smoke test (REST, gRPC, auth, metrics)
	@./scripts/smoke-test.sh
failover:  ## Stop a node, check service continues, bring it back (~1 min)
	@./scripts/failover-test.sh $(n)
seed:      ## Load 5000 sample points into collection "products" (idempotent)
	@set -a; . ./.env; set +a; ./scripts/seed.py
reset-data: ## Delete all collections; keep containers, metrics and dashboards
	@./scripts/reset-data.sh
snapshot:  ## Snapshot every node into ./backups
	@./scripts/snapshot.sh
restore:   ## make restore b=backups/<ts> c=<collection>
	@./scripts/restore.sh $(b) $(c)
replace-node: ## Rebuild a node from its peers: make replace-node N=1
	@./scripts/replace-node.sh $(N)
nuke:      ## DELETE all containers AND all data volumes
	@read -p "This deletes all Qdrant, Prometheus and Grafana data. Type yes: " a; [ "$$a" = yes ] && docker compose --profile host-metrics down -v
