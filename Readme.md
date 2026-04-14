# Private Multi-Region Global Load Balancing with Istio on AKS

A fully private, multi-region service mesh architecture using open-source Istio on Azure Kubernetes Service (AKS). Traffic is globally distributed across two private AKS clusters using Istio locality-aware load balancing, with automatic cross-region failover — no public endpoints required.

## Architecture

```
                    Azure Private DNS Zone
                  (internal.contoso.com — A records
                   pointing to both region ILB IPs)
                         │           │
              ┌──────────┘           └──────────┐
              ▼                                 ▼
    ┌─────────────────────┐          ┌─────────────────────┐
    │    Region: East US  │          │    Region: West US  │
    │                     │          │                     │
    │  ┌───────────────┐  │          │  ┌───────────────┐  │
    │  │  Azure ILB    │  │          │  │  Azure ILB    │  │
    │  │  (Private IP) │  │          │  │  (Private IP) │  │
    │  └───────┬───────┘  │          │  └───────┬───────┘  │
    │          ▼          │          │          ▼          │
    │  ┌───────────────┐  │          │  ┌───────────────┐  │
    │  │ Istio Ingress │  │          │  │ Istio Ingress │  │
    │  │   Gateway     │  │          │  │   Gateway     │  │
    │  └───────┬───────┘  │          │  └───────┬───────┘  │
    │          ▼          │  mTLS    │          ▼          │
    │  ┌───────────────┐  │◄────────►│  ┌───────────────┐  │
    │  │  AKS Cluster  │  │ East-   │  │  AKS Cluster  │  │
    │  │  (Istio mesh) │  │  West   │  │  (Istio mesh) │  │
    │  └───────────────┘  │ Gateway │  └───────────────┘  │
    │                     │          │                     │
    │  VNet: 10.1.0.0/16  │          │  VNet: 10.2.0.0/16  │
    └─────────────────────┘          └─────────────────────┘
              │                                 │
              └──────── VNet Peering ───────────┘
```

**How traffic flows:**

1. Internal clients resolve `api.internal.contoso.com` via Azure Private DNS, which returns ILB IPs for both regions (round-robin).
2. Requests hit the region-local Istio ingress gateway (internal load balancer).
3. Istio routes to local pods by default using **locality-aware load balancing**.
4. If local endpoints fail health checks (outlier detection), Istio automatically fails over to the remote region via the **east-west gateway** over mTLS.

## Repository Structure

```
├── infra/                          # Azure infrastructure (Bicep)
│   ├── main.bicep                  # Subscription-scoped orchestration
│   ├── main.bicepparam             # Deployment parameters
│   └── modules/
│       ├── aks.bicep               # Private AKS cluster + Flux GitOps
│       ├── vnet.bicep              # VNet with AKS and ILB subnets
│       ├── vnetPeering.bicep       # Bidirectional VNet peering
│       └── privateDnsZone.bicep    # Private DNS zone + VNet links
├── clusters/                       # Flux Kustomize source (synced to clusters)
│   ├── base/                       # Shared manifests applied to both clusters
│   │   ├── istio-system/           # PeerAuthentication, cross-network gateway
│   │   └── my-app/                 # DestinationRule, Gateway, VirtualService, AuthZ
│   ├── east/                       # East US overlay (IstioOperator for cluster-east)
│   └── west/                       # West US overlay (IstioOperator for cluster-west)
├── scripts/
│   └── deploy.ps1                  # Infrastructure deployment script
└── notes.md                        # Detailed architecture design notes
```

## What Gets Deployed

| Component | Details |
|---|---|
| **AKS Clusters** | 2 private clusters (East US, West US) with Azure CNI, availability zones, system + autoscaling user node pools |
| **Networking** | Dedicated VNets per region with AKS and ILB subnets, bidirectional VNet peering |
| **GitOps** | Flux v2 extension on each cluster, syncing Kustomize manifests from this repo |
| **Service Mesh** | Multi-primary Istio — each cluster runs its own control plane with shared root CA |
| **mTLS** | STRICT mode mesh-wide; cross-cluster mTLS via shared root CA and east-west gateways |
| **Load Balancing** | Locality-aware routing with automatic failover (outlier detection: 3 consecutive 5xx errors) |
| **DNS** | Azure Private DNS Zone linked to both VNets |

## Prerequisites

- Azure CLI with Bicep
- An Azure subscription with permissions to create resources at subscription scope
- A GitHub repository for Flux to pull Kustomize manifests from
- `istioctl` for cross-cluster remote secret setup (post-deploy)

## Deployment

### 1. Configure Parameters

Edit [`infra/main.bicepparam`](infra/main.bicepparam) and set your GitHub repository URL:

```bicep
param gitRepositoryUrl = 'https://github.com/colincmac/aks-multiregion-internal'
```

### 2. Deploy Infrastructure

```powershell
./scripts/deploy.ps1 -SubscriptionId "<your-subscription-id>"
```

This creates resource groups, VNets, VNet peering, both private AKS clusters with the Flux extension, and the Private DNS zone.

### 3. Post-Deployment — Istio Multi-Cluster Setup

After infrastructure is deployed, complete the cross-cluster mesh by exchanging remote secrets so each Istio control plane can discover services in the other cluster:

```bash
# Create a shared root CA secret in both clusters (before installing Istio)
kubectl create secret generic cacerts -n istio-system \
  --from-file=ca-cert.pem \
  --from-file=ca-key.pem \
  --from-file=root-cert.pem \
  --from-file=cert-chain.pem

# Exchange remote secrets for cross-cluster service discovery
istioctl create-remote-secret \
  --context="aks-west" \
  --name=cluster-west | \
  kubectl apply -f - --context="aks-east"

istioctl create-remote-secret \
  --context="aks-east" \
  --name=cluster-east | \
  kubectl apply -f - --context="aks-west"
```

> **Note:** Since these are private AKS clusters, ensure the API server private FQDNs are resolvable across peered VNets via Private DNS Zone forwarding.

### 4. Verify

```bash
# Check Flux sync status on each cluster
kubectl get fluxconfig -A --context="aks-east"
kubectl get fluxconfig -A --context="aks-west"

# Verify Istio sees endpoints in both clusters
istioctl proxy-config endpoints <pod> --context="aks-east" | grep my-api
```

## Key Design Decisions

- **Multi-primary mesh** — Each cluster operates independently; no single point of failure for the control plane.
- **Locality-aware routing** — Istio uses Kubernetes node topology labels (`topology.kubernetes.io/region`) to prefer local endpoints, only failing over to the remote region when outlier detection ejects unhealthy hosts.
- **Fully private** — No public IPs. All load balancers are internal, clusters use private API server endpoints, and DNS is via Azure Private DNS Zones.
- **GitOps with Flux** — Cluster configuration is declarative and version-controlled. Per-region Kustomize overlays allow region-specific Istio settings while sharing common policies.
- **Shared root CA** — Both clusters trust the same root certificate authority, enabling cross-cluster mTLS without terminating encryption at the gateway.
