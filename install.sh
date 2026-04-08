#!/usr/bin/env bash
# ============================================================
# Neo4j 5.26.24 Enterprise — 3-node cluster on drose-cluster2
# Helm chart based deployment (no operator)
# DNS : cluster.neo4jfield.org
# ============================================================
set -euo pipefail

NAMESPACE="neo4j"
CLUSTER_NAME="neo4j-ee-5-26-24-eks"
REGION="us-east-2"
EKS_CLUSTER="drose-cluster2"

echo ""
echo "=== Step 0: Point kubeconfig at drose-cluster2 ==="
aws eks update-kubeconfig --name "$EKS_CLUSTER" --region "$REGION"
kubectl config current-context

echo ""
echo "=== Step 1: Add Neo4j Helm repo ==="
helm repo add neo4j https://helm.neo4j.com/neo4j
helm repo update

echo ""
echo "=== Step 2: Create namespace ==="
kubectl get namespace "$NAMESPACE" &>/dev/null || kubectl create namespace "$NAMESPACE"

echo ""
echo "=== Step 3: Apply TLS secret ==="
kubectl apply -f neo4j-tls-secret.yaml -n "$NAMESPACE"

echo ""
echo "=== Step 4: Install cluster members (one per AZ) ==="

helm upgrade --install server-1 neo4j/neo4j \
  --namespace "$NAMESPACE" \
  --version 5.26.23 \
  -f server-1.values.yaml

helm upgrade --install server-2 neo4j/neo4j \
  --namespace "$NAMESPACE" \
  --version 5.26.23 \
  -f server-2.values.yaml

helm upgrade --install server-3 neo4j/neo4j \
  --namespace "$NAMESPACE" \
  --version 5.26.23 \
  -f server-3.values.yaml

echo ""
echo "=== Step 5: Install cluster headless service ==="
helm upgrade --install neo4j-ee-5-26-24-eks-headless neo4j/neo4j-cluster-headless-service \
  --namespace "$NAMESPACE" \
  -f headless.values.yaml

echo ""
echo "=== Step 6: Apply external NLB service (443→7473, 7687→7687) ==="
kubectl apply -f neo4j-lb-service.yaml

echo ""
echo "=== Step 7: Wait for pods to be ready (3-5 min) ==="
echo "Watching pod status — Ctrl+C to stop watching (install continues)"
kubectl get pods -n "$NAMESPACE" -w &
WATCH_PID=$!

# Give pods time to start
sleep 30

# Wait for all 3 server pods
for SERVER in server-1 server-2 server-3; do
  echo "Waiting for $SERVER-0 to be ready..."
  kubectl wait pod "${SERVER}-0" \
    -n "$NAMESPACE" \
    --for=condition=Ready \
    --timeout=300s || echo "WARNING: $SERVER-0 not Ready within 5 min — check logs"
done

kill $WATCH_PID 2>/dev/null || true

echo ""
echo "=== Step 8: Copy Bloom and GDS licenses into each pod ==="
for SERVER in server-1 server-2 server-3; do
  POD="${SERVER}-0"
  echo "  Copying licenses → $POD:/var/lib/neo4j/licenses/"
  kubectl exec -n "$NAMESPACE" "$POD" -- mkdir -p /var/lib/neo4j/licenses
  kubectl cp bloom-key.txt "$NAMESPACE/$POD:/var/lib/neo4j/licenses/bloom.license"
  kubectl cp gds-key.txt   "$NAMESPACE/$POD:/var/lib/neo4j/licenses/gds.license"
done

echo ""
echo "=== Step 9: Get NLB hostname ==="
echo "Waiting for NLB to be provisioned (may take ~2 min)..."
for i in $(seq 1 24); do
  NLB_HOST=$(kubectl get svc neo4j-lb -n "$NAMESPACE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
  if [ -n "$NLB_HOST" ]; then
    break
  fi
  echo "  ($i/24) Waiting..."
  sleep 10
done

echo ""
echo "============================================================"
echo " DEPLOYMENT COMPLETE"
echo "============================================================"
echo ""
echo "NLB hostname: ${NLB_HOST:-<not yet assigned — re-run: kubectl get svc neo4j-lb -n neo4j>}"
echo ""
echo ">>> DNS ACTION REQUIRED <<<"
echo "  Create a CNAME record in your domain registrar / DNS provider:"
echo "  CNAME  cluster.neo4jfield.org  →  ${NLB_HOST:-<NLB hostname>}"
echo ""
echo "Cluster status:"
kubectl get pods -n "$NAMESPACE"
echo ""
echo "Verify cluster formation (run after DNS propagates):"
echo "  kubectl exec -it server-1-0 -n neo4j -- \\"
echo "    cypher-shell -u neo4j -p 'P@55w0rd@2025' -d system 'SHOW SERVERS;'"
echo ""
echo "Access:"
echo "  Browser : https://cluster.neo4jfield.org        (port 443)"
echo "  Bolt+S  : neo4j+s://cluster.neo4jfield.org:7687"
echo "  Username: neo4j"
echo "  Password: P@55w0rd@2025"
echo ""
echo "NOTE: TLS cert is a Let's Encrypt wildcard (*.neo4jfield.org) — no hostname mismatch."
