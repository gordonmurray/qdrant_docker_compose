"""gRPC check against the HAProxy endpoint (run inside the tools image).
Env: HOST, PORT, KEY, COLLECTION (optional: search it and expect point id 1 first)."""
import os, sys, warnings
warnings.filterwarnings("ignore")
import grpc
from qdrant_client import QdrantClient

def client(key):
    return QdrantClient(host=os.environ["HOST"], grpc_port=int(os.environ["PORT"]), prefer_grpc=True,
                        check_compatibility=False, https=False, api_key=key, timeout=15)

c = client(os.environ["KEY"])
names = [x.name for x in c.get_collections().collections]
print("gRPC list collections ok:", len(names), "collections")

col = os.environ.get("COLLECTION")
if col:
    top = c.query_points(col, query=[0.9, 0.1, 0.1, 0.1], limit=1).points[0]
    if top.id != 1:
        sys.exit(f"gRPC search returned id {top.id}, expected 1")
    print("gRPC search returned the nearest point")

try:
    client(None).get_collections()
except grpc.RpcError as e:
    if e.code() not in (grpc.StatusCode.UNAUTHENTICATED, grpc.StatusCode.PERMISSION_DENIED):
        sys.exit(f"unauthenticated gRPC call failed with {e.code()}, expected UNAUTHENTICATED")
    print("gRPC without a key rejected:", e.code().name)
else:
    sys.exit("gRPC without a key was accepted")
