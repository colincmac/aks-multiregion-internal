# Private Multi-Region Global Load Balancing with Istio on AKS

A fully private, multi-region service mesh architecture using open-source Istio on Azure Kubernetes Service (AKS). Deploy any number of private AKS clusters across Azure regions — the infrastructure automatically creates full-mesh VNet peering, Flux GitOps, and Private DNS linking between all clusters. Istio locality-aware load balancing handles cross-region failover with no public endpoints.

## Architecture

```
                        Azure Private DNS Zone
                     (internal.contoso.com — A records
                      for each region's ILB private IP)
                        │          │         │
           ┌────────────┘          │         └────────────┐
           ▼                       ▼                      ▼
 ┌──────────────────┐   ┌──────────────────┐   ┌──────────────────┐
 │  Region A        │   │  Region B        │   │  Region N        │
 │  ┌────────────┐  │   │  ┌────────────┐  │   │  ┌────────────┐  │
 │  │ Azure ILB  │  │   │  │ Azure ILB  │  │   │  │ Azure ILB  │  │
 │  └─────┬──────┘  │   │  └─────┬──────┘  │   │  └─────┬──────┘  │
 │        ▼         │   │        ▼         │   │        ▼         │
 │  ┌────────────┐  │   │  ┌────────────┐  │   │  ┌────────────┐  │
 │  │Istio Ingress│ │   │  │Istio Ingress│ │   │  │Istio Ingress│ │
 │  │  Gateway   │  │   │  │  Gateway   │  │   │  │  Gateway   │  │
 │  └─────┬──────┘  │   │  └─────┬──────┘  │   │  └─────┬──────┘  │
 │        ▼         │   │        ▼         │   │        ▼         │
 │  ┌────────────┐  │   │  ┌────────────┐  │   │  ┌────────────┐  │
 │  │AKS Cluster │◄─┼──►│  │AKS Cluster │◄─┼──►│  │AKS Cluster │  │
 │  │(Istio mesh)│  │   │  │(Istio mesh)│  │   │  │(Istio mesh)│  │
 │  └────────────┘  │   │  └────────────┘  │   │  └────────────┘  │
 │  VNet: 10.1.0/16 │   │  VNet: 10.2.0/16 │   │  VNet: 10.N.0/16 │
 └──────────────────┘   └──────────────────┘   └──────────────────┘
          │                       │                      │
          └───── Full-Mesh VNet Peering ─────────────────┘
```

**How traffic flows:**

1. Internal clients resolve `api.internal.contoso.com` via Azure Private DNS, which returns ILB IPs for all regions (round-robin).
2. Requests hit the region-local Istio ingress gateway (internal load balancer).
3. Istio routes to local pods by default using **locality-aware load balancing**.
4. If local endpoints fail health checks (outlier detection), Istio automatically fails over to another region via **east-west gateways** over mTLS.

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
│   ├── base/                       # Shared manifests applied to all clusters
│   │   ├── istio-system/           # PeerAuthentication, cross-network gateway
│   │   └── my-app/                 # DestinationRule, Gateway, VirtualService, AuthZ
│   └── <region>/                   # Per-region overlay (IstioOperator for that cluster)
├── scripts/
│   └── deploy.ps1                  # Infrastructure deployment script
└── notes.md                        # Detailed architecture design notes
```

## What Gets Deployed

| Component | Details |
|---|---|
| **AKS Clusters** | N private clusters (any Azure regions) with Azure CNI, availability zones, system + autoscaling user node pools |
| **Networking** | Dedicated VNet per cluster with AKS and ILB subnets, automatic full-mesh VNet peering |
| **GitOps** | Flux v2 extension on each cluster, syncing per-region Kustomize manifests from this repo |
| **Service Mesh** | Multi-primary Istio — each cluster runs its own control plane with shared root CA |
| **mTLS** | STRICT mode mesh-wide; cross-cluster mTLS via shared root CA and east-west gateways |
| **Load Balancing** | Locality-aware routing with automatic failover (outlier detection: 3 consecutive 5xx errors) |
| **DNS** | Azure Private DNS Zone linked to all cluster VNets |

## Prerequisites

- Azure CLI with Bicep
- An Azure subscription with permissions to create resources at subscription scope
- A GitHub repository for Flux to pull Kustomize manifests from
- `istioctl` for cross-cluster remote secret setup (post-deploy)

## Deployment

### 1. Configure Parameters

Edit [`infra/main.bicepparam`](infra/main.bicepparam) — set your GitHub repository URL and define your clusters:

```bicep
param gitRepositoryUrl = 'https://github.com/colincmac/aks-multiregion-internal'

param clusters = [
  {
    name: 'eastus2'
    location: 'eastus2'
    addressPrefix: '10.1.0.0/16'
    aksSubnetPrefix: '10.1.0.0/20'
    ilbSubnetPrefix: '10.1.16.0/24'
    kustomizationPath: './clusters/eastus2'
  }
  {
    name: 'centralus'
    location: 'centralus'
    addressPrefix: '10.2.0.0/16'
    aksSubnetPrefix: '10.2.0.0/20'
    ilbSubnetPrefix: '10.2.16.0/24'
    kustomizationPath: './clusters/centralus'
  }
  // Add more clusters as needed — use non-overlapping address prefixes
]
```

Each entry in `clusters` provisions a resource group, VNet, private AKS cluster with Flux, and full-mesh VNet peering to all other clusters. Ensure each cluster has a unique `name` and non-overlapping `addressPrefix`.

For each cluster, create a corresponding Kustomize overlay under `clusters/<name>/` with the region-specific IstioOperator configuration.

### 2. Deploy Infrastructure

```powershell
./scripts/deploy.ps1 -SubscriptionId "<your-subscription-id>"
```

This creates resource groups, full-mesh VNet peering, private AKS clusters with Flux, and the shared Private DNS zone — scaled to however many clusters are defined.

### 3. Post-Deployment — Istio Multi-Cluster Setup

After infrastructure is deployed, complete the cross-cluster mesh by exchanging remote secrets so each Istio control plane can discover services in the other cluster:

```bash
# Create a shared root CA secret in ALL clusters (before installing Istio)
for CTX in aks-eastus2 aks-centralus; do
  kubectl create secret generic cacerts -n istio-system \
    --from-file=ca-cert.pem \
    --from-file=ca-key.pem \
    --from-file=root-cert.pem \
    --from-file=cert-chain.pem \
    --context="$CTX"
done

# Exchange remote secrets — each cluster needs a secret for every other cluster
CLUSTERS=(aks-eastus2 aks-centralus)  # add more as needed
for SRC in "${CLUSTERS[@]}"; do
  for DST in "${CLUSTERS[@]}"; do
    if [ "$SRC" != "$DST" ]; then
      istioctl create-remote-secret \
        --context="$SRC" \
        --name="$SRC" | \
        kubectl apply -f - --context="$DST"
    fi
  done
done
```

> **Note:** Since these are private AKS clusters, ensure the API server private FQDNs are resolvable across peered VNets via Private DNS Zone forwarding.

### 4. Verify

```bash
# Check Flux sync status on each cluster
for CTX in aks-eastus2 aks-centralus; do
  echo "--- $CTX ---"
  kubectl get fluxconfig -A --context="$CTX"
done

# Verify Istio sees endpoints across clusters
istioctl proxy-config endpoints <pod> --context="aks-eastus2" | grep my-api
```

## Key Design Decisions

- **N-cluster scalability** — Define clusters in a single parameter array. VNet peering, DNS linking, and Flux configuration scale automatically.
- **Multi-primary mesh** — Each cluster operates independently; no single point of failure for the control plane.
- **Locality-aware routing** — Istio uses Kubernetes node topology labels (`topology.kubernetes.io/region`) to prefer local endpoints, only failing over to other regions when outlier detection ejects unhealthy hosts.
- **Full-mesh networking** — Every cluster VNet is peered with every other, enabling direct pod-to-pod communication across all regions.
- **Fully private** — No public IPs. All load balancers are internal, clusters use private API server endpoints, and DNS is via Azure Private DNS Zones.
- **GitOps with Flux** — Cluster configuration is declarative and version-controlled. Per-region Kustomize overlays allow region-specific Istio settings while sharing common policies.
- **Shared root CA** — All clusters trust the same root certificate authority, enabling cross-cluster mTLS without terminating encryption at the gateway.
