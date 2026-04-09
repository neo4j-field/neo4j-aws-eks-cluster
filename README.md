# Neo4j Enterprise Cluster on AWS EKS

A production-ready Helm-based deployment of a 3-node Neo4j Enterprise cluster on Amazon EKS — no operator required.

## Architecture

```
                        ┌─────────────────────────────┐
Internet ──► AWS NLB ──►│ Neo4j EKS Cluster (neo4j ns)│
  443 → 7473 (HTTPS)    │                             │
  7687 → 7687 (Bolt+S)  │ server-1  server-2  server-3│
                        │  (AZ-a)    (AZ-b)   (AZ-c)  │
                        └─────────────────────────────┘
```

- **3 StatefulSet pods**, one per Availability Zone (us-east-2a/b/c)
- **TLS end-to-end** — NLB passes TCP through; Neo4j terminates TLS internally
- **Bloom 6.x + GDS** loaded via init container from `/products → /plugins`
- **Causal clustering** via headless service DNS discovery
- **Passwords and license keys** stored as Kubernetes secrets — never in values files

## Prerequisites

| Tool | Version |
|------|---------|
| `kubectl` | ≥ 1.28 |
| `helm` | ≥ 3.12 |
| `aws` CLI | ≥ 2.x |
| `gh` CLI | any |

Add the Neo4j Helm repo:
```bash
helm repo add neo4j https://helm.neo4j.com/neo4j
helm repo update
```

## File Overview

| File | Purpose |
|------|---------|
| `install.sh` | End-to-end deployment script |
| `server-1/2/3.values.yaml` | Per-member Helm values (AZ-pinned) |
| `headless.values.yaml` | Headless service for intra-cluster discovery |
| `neo4j-lb-service.yaml` | AWS NLB LoadBalancer service (443, 7687) |
| `neo4j-tls-secret.yaml` | Template for the TLS secret (fill in your cert/key) |

## Setup

### 1. Create Kubernetes secrets

**Neo4j password:**
```bash
kubectl create secret generic neo4j-ee-5-26-23-eks-auth \
  --from-literal=NEO4J_AUTH='neo4j/<YOUR_NEO4J_PASSWORD>' \
  -n neo4j
```

**TLS certificate** (fill in your cert and key in `neo4j-tls-secret.yaml` first):
```bash
kubectl apply -f neo4j-tls-secret.yaml -n neo4j
```

**Bloom and GDS licenses:**
```bash
kubectl create secret generic neo4j-licenses \
  --from-file=bloom.license=<path-to-bloom-license-file> \
  --from-file=gds.license=<path-to-gds-license-file> \
  -n neo4j
```

### 2. Run the install script
```bash
# Edit the variables at the top of install.sh first
chmod +x install.sh
./install.sh
```

### 3. DNS

After the NLB is provisioned, get its hostname:
```bash
kubectl get svc neo4j-lb -n neo4j -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Create a CNAME in your DNS provider:
```
CNAME  <your-subdomain>.<your-domain>  →  <NLB hostname>
```

## Accessing the Cluster

| Interface | URL |
|-----------|-----|
| Neo4j Browser | `https://<your-domain>` |
| Bolt+S | `neo4j+s://<your-domain>:7687` |
| Bloom | `https://<your-domain>/bloom/index.html` |

## Security Notes

- **Passwords** — stored in a Kubernetes secret (`neo4j-ee-5-26-23-eks-auth`), referenced via `passwordFromSecret` in values files. Never committed to source control.
- **License keys** — stored in a Kubernetes secret (`neo4j-licenses`), mounted as files into each pod. The `bloom-key.txt` and `gds-key.txt` files are in `.gitignore`.
- **TLS private key** — stored in a Kubernetes secret (`neo4j-tls`). The `private.key` file is in `.gitignore`.

## Upgrading

Rolling upgrade (one member at a time to maintain cluster quorum):
```bash
helm upgrade server-1 neo4j/neo4j -n neo4j -f server-1.values.yaml
# wait for server-1-0 to be Ready, then:
helm upgrade server-2 neo4j/neo4j -n neo4j -f server-2.values.yaml
helm upgrade server-3 neo4j/neo4j -n neo4j -f server-3.values.yaml
```

## Verifying the Cluster

```bash
kubectl exec -it server-1-0 -n neo4j -- \
  cypher-shell -u neo4j -p '<YOUR_NEO4J_PASSWORD>' -d system 'SHOW SERVERS;'
```
