#!/usr/bin/env python3
"""Idempotent sample data: a `products` collection with 384-d vectors, payload
indexes and 5000 points. Re-running upserts the same ids with the same values.
Standard library only. Usage: seed.py [--points N] [--collection NAME]"""
import argparse, json, os, random, urllib.request, urllib.error

p = argparse.ArgumentParser()
p.add_argument("--points", type=int, default=5000)
p.add_argument("--collection", default="products")
p.add_argument("--dim", type=int, default=384)
a = p.parse_args()

url = f"http://127.0.0.1:{os.environ.get('QDRANT_REST_PORT', '6333')}"
key = os.environ["QDRANT_API_KEY"]

def call(method, path, body=None):
    req = urllib.request.Request(url + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"api-key": key, "content-type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        raise SystemExit(f"{method} {path}: {e.code} {e.read().decode()}")

exists = any(c["name"] == a.collection for c in call("GET", "/collections")["result"]["collections"])
if not exists:
    # Uses the cluster defaults for replication factor and write consistency.
    call("PUT", f"/collections/{a.collection}?wait=true", {
        "vectors": {"size": a.dim, "distance": "Cosine"},
        "shard_number": 3,
        "hnsw_config": {"m": 16, "ef_construct": 100},
    })
    print(f"created collection {a.collection}")
for field, schema in (("category", "keyword"), ("price", "float"), ("in_stock", "bool"), ("created", "integer")):
    call("PUT", f"/collections/{a.collection}/index?wait=true", {"field_name": field, "field_schema": schema})

rng = random.Random(42)
cats = ["books", "garden", "kitchen", "toys", "sports", "music"]
batch = 250
for start in range(0, a.points, batch):
    pts = []
    for i in range(start, min(start + batch, a.points)):
        pts.append({"id": i + 1,
                    "vector": [round(rng.gauss(0, 1), 4) for _ in range(a.dim)],
                    "payload": {"category": cats[i % len(cats)], "price": round(rng.uniform(1, 500), 2),
                                "in_stock": rng.random() > 0.2, "created": 1_700_000_000 + i * 3600,
                                "title": f"Product {i + 1}"}})
    call("PUT", f"/collections/{a.collection}/points?wait=true", {"points": pts})
n = call("POST", f"/collections/{a.collection}/points/count", {"exact": True})["result"]["count"]
print(f"{a.collection}: {n} points")
