#!/usr/bin/env bash
# ============================================================
# Neo4j Enterprise — 3-node cluster on AWS EKS
# Helm chart based deployment (no operator)
# ============================================================
set -euo pipefail

# ── Configuration — edit these before running ────────────────
NAMESPACE="neo4j"
CLUSTER_NAME="neo4j-ee-5-26-23-eks"
REGION="us-east-2"
EKS_CLUSTER="<YOUR_EKS_CLUSTER_NAME>"
NEO4J_VERSION="5.26.23"
YOUR_DOMAIN="<YOUR_SUBDOMAIN>.<YOUR_DOMAIN>"   # e.g. neo4j.example.com
# ─────────────────────────────────────────────────────────────

echo ""
echo "=== Step 0: Point kubeconfig at EKS cluster ==="
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
echo "=== Step 3: Create secrets (password, TLS, licenses) ==="

# Neo4j password secret
if kubectl get secret "${CLUSTER_NAME}-auth" -n "$NAMESPACE" &>/dev/null; then
  echo "  Auth secret already exists — skipping"
else
  echo "  Creating auth secret..."
  read -rsp "  Enter Neo4j password: " NEO4J_PASSWORD
  echo ""
  kubectl create secret generic "${CLUSTER_NAME}-auth" \
    --from-literal=NEO4J_AUTH="neo4j/${NEO4J_PASSWORD}" \
    -n "$NAMESPACE"
fi

# TLS secret (fill in neo4j-tls-secret.yaml first)
kubectl apply -f neo4j-tls-secret.yaml -n "$NAMESPACE"

# Bloom and GDS licenses
# Place your license files at bloom.license and gds.license before running
if [ -f bloom.license ] && [ -f gds.license ]; then
  kubectl create secret generic neo4j-licenses \
    --from-file=bloom.license=bloom.license \
    --from-file=gds.license=gds.license \
    -n "$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
else
  echo "  WARNING: bloom.license and/or gds.license not found."
  echo "  Obtain your license files from https://neo4j.com/licensing/ and re-run."
fi

echo ""
echo "=== Step 4: Install cluster members (one per AZ) ==="

helm upgrade --install server-1 neo4j/neo4j \
  --namespace "$NAMESPACE" \
  --version "$NEO4J_VERSION" \
  -f server-1.values.yaml

helm upgrade --install server-2 neo4j/neo4j \
  --namespace "$NAMESPACE" \
  --version "$NEO4J_VERSION" \
  -f server-2.values.yaml

helm upgrade --install server-3 neo4j/neo4j \
  --namespace "$NAMESPACE" \
  --version "$NEO4J_VERSION" \
  -f server-3.values.yaml

echo ""
echo "=== Step 5: Install cluster headless service ==="
helm upgrade --install "${CLUSTER_NAME}-headless" neo4j/neo4j-cluster-headless-service \
  --namespace "$NAMESPACE" \
  -f headless.values.yaml

echo ""
echo "=== Step 6: Apply external NLB service (443→7473, 7687→7687) ==="
kubectl apply -f neo4j-lb-service.yaml

echo ""
echo "=== Step 7: Wait for pods to be ready (3-5 min) ==="
kubectl get pods -n "$NAMESPACE" -w &
WATCH_PID=$!
sleep 30

for SERVER in server-1 server-2 server-3; do
  echo "Waiting for $SERVER-0 to be ready..."
  kubectl wait pod "${SERVER}-0" \
    -n "$NAMESPACE" \
    --for=condition=Ready \
    --timeout=300s || echo "WARNING: $SERVER-0 not Ready within 5 min — check logs"
done

kill $WATCH_PID 2>/dev/null || true

echo ""
echo "=== Step 8: Get NLB hostname ==="
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
echo "  Create a CNAME in your DNS provider:"
echo "  CNAME  ${YOUR_DOMAIN}  →  ${NLB_HOST:-<NLB hostname>}"
echo ""
echo "Cluster status:"
kubectl get pods -n "$NAMESPACE"
echo ""
echo "Access:"
echo "  Browser : https://${YOUR_DOMAIN}"
echo "  Bolt+S  : neo4j+s://${YOUR_DOMAIN}:7687"
echo "  Bloom   : https://${YOUR_DOMAIN}/bloom/index.html"
echo "  Username: neo4j"
echo ""
echo "Verify cluster formation:"
echo "  kubectl exec -it server-1-0 -n neo4j -- \\"
echo "    cypher-shell -u neo4j -p '<YOUR_NEO4J_PASSWORD>' -d system 'SHOW SERVERS;'"
