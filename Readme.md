# Private Multi-Region Global Load Balancing with Istio Ambient Mode on AKS

A fully private, multi-region service mesh architecture using **Istio Ambient Mode** on Azure Kubernetes Service (AKS), managed via **Flux GitOps**. Deploy any number of private AKS clusters across Azure regions — the infrastructure automatically creates full-mesh VNet peering, Flux GitOps, and Private DNS linking between all clusters. Istio ambient mode provides mTLS, L4/L7 policy enforcement via waypoint proxies, and locality-aware load balancing with cross-region failover.

## Architecture

```
                        Azure Private DNS Zone
                     (internal.contoso.com — A records
                      for each region's ILB private IP)
                        │          │         │
           ┌────────────┘          │         └────────────┐
           ▼                       ▼                      ▼
 ┌──────────────────┐   ┌──────────────────┐   ┌──────────────────┐
 │  Region East     │   │  Region West     │   │  Region N        │
 │  ┌────────────┐  │   │  ┌────────────┐  │   │  ┌────────────┐  │
 │  │ Azure ILB  │  │   │  │ Azure ILB  │  │   │  │ Azure ILB  │  │
 │  └─────┬──────┘  │   │  └─────┬──────┘  │   │  └─────┬──────┘  │
 │        ▼         │   │        ▼         │   │        ▼         │
 │  ┌────────────┐  │   │  ┌────────────┐  │   │  ┌────────────┐  │
 │  │K8s Gateway │  │   │  │K8s Gateway │  │   │  │K8s Gateway │  │
 │  │(istio GWC) │  │   │  │(istio GWC) │  │   │  │(istio GWC) │  │
 │  └─────┬──────┘  │   │  └─────┬──────┘  │   │  └─────┬──────┘  │
 │        ▼         │   │        ▼         │   │        ▼         │
 │  ┌────────────┐  │   │  ┌────────────┐  │   │  ┌────────────┐  │
 │  │AKS Cluster │◄─┼──►│  │AKS Cluster │◄─┼──►│  │AKS Cluster │  │
 │  │ ztunnel +  │  │   │  │ ztunnel +  │  │   │  │ ztunnel +  │  │
 │  │  waypoint  │  │   │  │  waypoint  │  │   │  │  waypoint  │  │
 │  │ (ambient)  │  │   │  │ (ambient)  │  │   │  │ (ambient)  │  │
 │  └────────────┘  │   │  └────────────┘  │   │  └────────────┘  │
 │  VNet: 10.1.0/16 │   │  VNet: 10.2.0/16 │   │  VNet: 10.N.0/16 │
 └──────────────────┘   └──────────────────┘   └──────────────────┘
          │                       │                      │
          └─── HBONE/mTLS (15008) E-W Gateways ──────────┘
          │                                              │
          └───── Full-Mesh VNet Peering ─────────────────┘
```

**How traffic flows:**

1. Internal clients resolve `api.internal.contoso.com` via Azure Private DNS, which returns ILB IPs for all regions (round-robin).
2. Requests hit the region-local Kubernetes Gateway API `Gateway` resource (Istio gateway class), backed by an internal Azure load balancer.
3. Istio ambient mode routes to local pods by default using **locality-aware load balancing** with `failoverPriority: [topology.istio.io/cluster]`.
4. L7 policy (outlier detection, locality failover) is enforced by the **waypoint proxy** (`gatewayClassName: istio-waypoint`) in each namespace.
5. If local endpoints fail health checks (1 consecutive 5xx error triggers outlier detection), the waypoint proxy automatically fails over to healthy instances in another cluster via **east-west gateways** over HBONE/mTLS on port 15008.

## Failover Scenarios

This solution handles three distinct failure scenarios, modelled after the [Tetrate edge-failover pattern](https://docs.tetrate.io/service-bridge/getting-started/use-cases/tier1-tier2/edge-failover):

### Scenario 1 — Partial Workload Failure (single service down, cluster healthy)
If a specific workload (e.g. `my-api`) fails health checks in one cluster but the rest of the cluster is healthy, outlier detection (`consecutive5xxErrors: 1`, `interval: 1s`) ejects only the unhealthy service endpoints. Traffic for that service fails over to healthy instances in another cluster while all other services in the same cluster continue operating normally. No DNS change is needed.

### Scenario 2 — Full Regional Failure (entire cluster/network unreachable)
If an entire cluster/region goes down (network loss, AKS outage), all its endpoints become unreachable. Istio's locality failover (`failoverPriority: [topology.istio.io/cluster]`) routes all in-mesh traffic to the surviving cluster(s) automatically. Additionally, because the Kubernetes Services annotated for ExternalDNS no longer exist (the cluster is down), ExternalDNS on the surviving cluster eventually cleans up stale TXT owner records, and DNS clients' TTL expiry redirects traffic away.

### Scenario 3 — All Local Workloads Down, Gateway Still Up (DNS GSLB failover)
**This is the most subtle scenario**: the Istio ingress gateway is still reachable and accepting connections, but all `my-api` pods in the cluster are failing. Istio's in-mesh failover handles this correctly for mesh-internal traffic, but external clients resolving `api.internal.contoso.com` from DNS still get directed to the "dead region's" ILB IP — adding unnecessary cross-region latency.

The **health-check controller + ExternalDNS** integration solves this:
1. The health-check controller continuously probes `my-api.my-app.svc.cluster.local:8080` directly (not through the gateway, to avoid masking the failure via cross-region failover)
2. After 3 consecutive failures (~15s), it deletes the `api-dns-record` Service from the `health-check` namespace
3. ExternalDNS detects the annotation is gone (via `--policy=sync`) and removes the A record for `api.internal.contoso.com` from Azure Private DNS
4. With TTL=30s, DNS clients stop being directed to the failing region within ~55s total
5. When `my-api` recovers, the controller recreates the Service and ExternalDNS re-adds the A record

## DNS-Based GSLB Architecture

```
                    Azure Private DNS Zone (internal.contoso.com)
                    ┌──────────────────────────────────────────┐
                    │  api  →  [10.1.10.50, 10.2.10.50]       │  ← managed by ExternalDNS
                    │  _externaldns-api.TXT → owner records    │  ← TXT records track ownership
                    └──────────────────────────────────────────┘
                            ▲                        ▲
                            │ A record               │ A record
                   ┌────────┴──────────┐   ┌────────┴──────────┐
                   │  ExternalDNS      │   │  ExternalDNS      │
                   │  (cluster-east)   │   │  (cluster-west)   │
                   │  watches:         │   │  watches:         │
                   │  api-dns-record   │   │  api-dns-record   │
                   │  Service          │   │  Service          │
                   └────────▲──────────┘   └────────▲──────────┘
                            │                        │
                   ┌────────┴──────────┐   ┌────────┴──────────┐
                   │  Health-Check     │   │  Health-Check     │
                   │  Controller       │   │  Controller       │
                   │  ┌─────────────┐  │   │  ┌─────────────┐  │
                   │  │probes my-api│  │   │  │probes my-api│  │
                   │  │ directly    │  │   │  │ directly    │  │
                   │  └──────┬──────┘  │   │  └──────┬──────┘  │
                   │  healthy│         │   │  healthy│         │
                   │  → keep │Service  │   │  → keep │Service  │
                   │  unhealthy        │   │  unhealthy        │
                   │  → delete│Service │   │  → delete│Service │
                   └──────────┴────────┘   └──────────┴────────┘
                        East Cluster             West Cluster
```

**Key design properties:**
- **Per-cluster ownership**: Each ExternalDNS uses a unique `--txt-owner-id` (`cluster-east` / `cluster-west`) so each instance only manages its own A record contribution
- **Fast failover**: TTL=30s + probe interval=5s + fail threshold=3 + ExternalDNS poll interval=10s = ~55s worst-case
- **Automatic recovery**: Controller recreates the DNS Service when backends recover; ExternalDNS re-adds the A record
- **Fully private**: ExternalDNS manages Azure *Private* DNS Zone records — no public endpoints involved
- **GitOps-compatible**: All resources are Kustomize manifests managed by Flux

## Repository Structure

```
├── infra/                          # Azure infrastructure (Bicep)
│   ├── main.bicep                  # Subscription-scoped orchestration
│   ├── main.bicepparam             # Deployment parameters
│   └── modules/
│       ├── aks.bicep               # Private AKS cluster + Flux GitOps + ExternalDNS workload identity
│       ├── vnet.bicep              # VNet with AKS and ILB subnets
│       ├── vnetPeering.bicep       # Bidirectional VNet peering
│       └── privateDnsZone.bicep    # Private DNS zone + VNet links
├── clusters/                       # Flux Kustomize source (synced to clusters)
│   ├── base/                       # Shared manifests applied to all clusters
│   │   ├── gateway-api/            # Gateway API CRD bundle (Kustomization)
│   │   ├── gateway-api-crds.yaml   # Flux Kustomization for Gateway API CRDs
│   │   ├── istio-helm-repo.yaml    # Flux HelmRepository for Istio charts
│   │   ├── istio-system/           # Shared: namespace, PeerAuthentication,
│   │   │                           #   HelmRelease for istio/base and istio/cni
│   │   ├── my-app/                 # DestinationRule, K8s Gateway, HTTPRoute,
│   │   │                           #   AuthorizationPolicy, waypoint, Service
│   │   ├── health-check/           # Health-check controller (Scenario 3 detection)
│   │   │   ├── namespace.yaml      #   Namespace with ambient mesh label
│   │   │   ├── serviceaccount.yaml #   ServiceAccount for RBAC
│   │   │   ├── role.yaml           #   Roles: manage Services + read Endpoints
│   │   │   ├── rolebinding.yaml    #   RoleBindings
│   │   │   ├── configmap.yaml      #   Controller script + dns-service.yaml template
│   │   │   ├── deployment.yaml     #   Controller Deployment (probes + HTTP server)
│   │   │   ├── service.yaml        #   ClusterIP service exposing /healthz
│   │   │   ├── externaldns-service.yaml # ExternalDNS-annotated Service (managed dynamically)
│   │   │   └── kustomization.yaml
│   │   └── external-dns/           # ExternalDNS for Azure Private DNS
│   │       ├── namespace.yaml
│   │       ├── serviceaccount.yaml #   ServiceAccount (workload identity annotation added per-cluster)
│   │       ├── clusterrole.yaml
│   │       ├── clusterrolebinding.yaml
│   │       ├── deployment.yaml     #   ExternalDNS with azure-private-dns provider
│   │       └── kustomization.yaml
│   ├── east/                       # East cluster overlay
│   │   ├── helmrelease-istiod.yaml # istiod with cluster-east settings
│   │   ├── helmrelease-ztunnel.yaml# ztunnel for network-east
│   │   ├── east-west-gateway.yaml  # Ambient east-west Gateway (HBONE/15008)
│   │   ├── istio-system-patch.yaml # topology.istio.io/network label patch
│   │   ├── externaldns-patch.yaml  # --txt-owner-id=cluster-east patch
│   │   └── kustomization.yaml
│   └── west/                       # West cluster overlay (mirror of east)
│       ├── helmrelease-istiod.yaml
│       ├── helmrelease-ztunnel.yaml
│       ├── east-west-gateway.yaml
│       ├── istio-system-patch.yaml
│       ├── externaldns-patch.yaml  # --txt-owner-id=cluster-west patch
│       └── kustomization.yaml
├── scripts/
│   └── deploy.ps1                  # Infrastructure deployment script
└── notes.md                        # Detailed architecture design notes
```

## What Gets Deployed

| Component | Details |
|---|---|
| **AKS Clusters** | N private clusters (any Azure regions) with Azure CNI, availability zones, system + autoscaling user node pools, OIDC issuer + Workload Identity enabled |
| **Networking** | Dedicated VNet per cluster with AKS and ILB subnets, automatic full-mesh VNet peering |
| **GitOps** | Flux v2 extension on each cluster, syncing per-region Kustomize manifests from this repo |
| **Service Mesh** | Multi-primary Istio **Ambient Mode** — each cluster runs its own control plane (istiod) with shared root CA; ztunnel replaces sidecars |
| **mTLS** | STRICT mode mesh-wide via ztunnel; cross-cluster mTLS via shared root CA and east-west HBONE gateways |
| **L7 Policy** | Waypoint proxies per namespace enforce outlier detection, locality failover, and AuthorizationPolicies |
| **Load Balancing** | Locality-aware routing with `failoverPriority: [topology.istio.io/cluster]`; outlier detection: 1 consecutive 5xx → immediate failover |
| **Ingress** | Kubernetes Gateway API (`gateway.networking.k8s.io/v1`) with `gatewayClassName: istio`, backed by internal Azure LBs |
| **DNS** | Azure Private DNS Zone linked to all cluster VNets; A records managed dynamically by ExternalDNS |
| **Health-Check Controller** | Per-cluster controller probing local `my-api` endpoints; deletes DNS Service on failure for Scenario 3 detection |
| **ExternalDNS** | Per-cluster ExternalDNS with Azure Private DNS provider; watches annotated Services and maintains A records with per-cluster TXT ownership |
| **Workload Identity** | Per-cluster User-Assigned Managed Identity for ExternalDNS with Private DNS Zone Contributor role and federated credential |

## Prerequisites

- Azure CLI with Bicep
- An Azure subscription with permissions to create resources at subscription scope
- A GitHub repository for Flux to pull Kustomize manifests from

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
    kustomizationPath: './clusters/east'
  }
  {
    name: 'centralus'
    location: 'centralus'
    addressPrefix: '10.2.0.0/16'
    aksSubnetPrefix: '10.2.0.0/20'
    ilbSubnetPrefix: '10.2.16.0/24'
    kustomizationPath: './clusters/west'
  }
  // Add more clusters as needed — use non-overlapping address prefixes
]
```

### 2. Deploy Infrastructure

```powershell
./scripts/deploy.ps1 -SubscriptionId "<your-subscription-id>"
```

This creates resource groups, full-mesh VNet peering, private AKS clusters with Flux, and the shared Private DNS zone.

### 3. Post-Deployment — Istio Multi-Cluster Setup

After infrastructure is deployed, complete the cross-cluster mesh by sharing a root CA and exchanging remote secrets:

```bash
# 1. Create a shared root CA secret in ALL clusters (before Flux installs Istio)
for CTX in aks-eastus2 aks-centralus; do
  kubectl create secret generic cacerts -n istio-system \
    --from-file=ca-cert.pem \
    --from-file=ca-key.pem \
    --from-file=root-cert.pem \
    --from-file=cert-chain.pem \
    --context="$CTX"
done

# 2. Exchange remote secrets — each cluster needs a secret for every other cluster
CLUSTERS=(aks-eastus2 aks-centralus)
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

> **Note:** Since these are private AKS clusters, ensure the API server private FQDNs are resolvable across peered VNets via Private DNS Zone forwarding before exchanging remote secrets.

> **Note:** The `cacerts` secret must be created **before** Flux installs Istio (before the `istiod` HelmRelease reconciles) to ensure istiod uses the shared root CA from the start.

### 3b. Post-Deployment — ExternalDNS Workload Identity Setup

The Bicep infrastructure creates a User-Assigned Managed Identity for ExternalDNS in each cluster's resource group and grants it `Private DNS Zone Contributor` on the shared DNS zone. You need to annotate the ExternalDNS ServiceAccount and create the Azure auth secret in each cluster:

```bash
# Get the ExternalDNS managed identity client IDs from the Bicep outputs
EAST_CLIENT_ID=$(az deployment sub show \
  --name "deploy-istio-mesh" \
  --query "properties.outputs.aksEastus2ExternalDnsIdentityClientId.value" -o tsv)

WEST_CLIENT_ID=$(az deployment sub show \
  --name "deploy-istio-mesh" \
  --query "properties.outputs.aksCentralusExternalDnsIdentityClientId.value" -o tsv)

SUBSCRIPTION_ID=$(az account show --query id -o tsv)
RESOURCE_GROUP="rg-istio-mesh-global"

# Annotate the ExternalDNS ServiceAccount for Workload Identity in each cluster
kubectl annotate serviceaccount external-dns \
  -n external-dns \
  "azure.workload.identity/client-id=${EAST_CLIENT_ID}" \
  --context=aks-eastus2

kubectl annotate serviceaccount external-dns \
  -n external-dns \
  "azure.workload.identity/client-id=${WEST_CLIENT_ID}" \
  --context=aks-centralus

# Create the Azure subscription secret for ExternalDNS (used for the azure-private-dns provider)
for CTX in aks-eastus2 aks-centralus; do
  kubectl create secret generic external-dns-azure \
    -n external-dns \
    --from-literal=subscription-id="${SUBSCRIPTION_ID}" \
    --context="${CTX}" \
    --dry-run=client -o yaml | kubectl apply -f - --context="${CTX}"
done
```

> **DNS TTL consideration:** The `api-dns-record` Service annotation sets TTL=30s. Combined with the health-check probe interval (5s), fail threshold (3 consecutive failures = 15s), and ExternalDNS polling interval (10s), the worst-case failover time is ~55s. For faster failover, reduce the TTL and/or the ExternalDNS `--interval`, but note that Azure Private DNS has a minimum TTL of 1s.

### 4. Verify

```bash
# Check Flux HelmRelease status on each cluster
for CTX in aks-eastus2 aks-centralus; do
  echo "--- $CTX ---"
  kubectl get helmrelease -n istio-system --context="$CTX"
  kubectl get helmrelease -n flux-system --context="$CTX"
done

# Check ambient mode is active
kubectl get pods -n istio-system --context=aks-eastus2
# Should see: istiod, istio-cni-node, ztunnel (no sidecar injectors)

# Verify waypoint proxy is running in my-app namespace
kubectl get gateway -n my-app --context=aks-eastus2

# Verify Istio sees endpoints across clusters
istioctl proxy-config endpoints <ztunnel-pod> -n istio-system --context=aks-eastus2 | grep my-api
```

## Key Design Decisions

- **Ambient Mode (no sidecars)** — ztunnel handles L4 mTLS transparently for all pods without sidecar injection. Waypoint proxies provide optional L7 policy enforcement per namespace/service.
- **Waypoint proxies for L7 failover** — Required for outlier detection and locality-based failover in ambient mode. The `waypoint` Gateway resource (`istio.io/waypoint-for: service`) is shared across clusters.
- **HBONE east-west gateways** — Cross-cluster traffic uses HBONE (HTTP-Based Overlay Network Encapsulation) on port 15008 instead of the legacy TLS-passthrough on port 15443. Each cluster has its own east-west Gateway with `gatewayClassName: istio-east-west`.
- **Kubernetes Gateway API** — North-south ingress uses `gateway.networking.k8s.io/v1` `Gateway` + `HTTPRoute` instead of the legacy Istio `Gateway`/`VirtualService` API.
- **Flux HelmRelease for Istio** — No `helm install` or `istioctl install` commands. The four ambient Helm charts (base → istiod → cni → ztunnel) are installed in dependency order by Flux.
- **N-cluster scalability** — Define clusters in a single parameter array. VNet peering, DNS linking, and Flux configuration scale automatically.
- **Multi-primary mesh** — Each cluster operates independently; no single point of failure for the control plane.
- **Fully private** — No public IPs. All load balancers use `service.beta.kubernetes.io/azure-load-balancer-internal: "true"`, clusters use private API server endpoints, and DNS is via Azure Private DNS Zones.
- **Shared root CA** — All clusters trust the same root certificate authority, enabling cross-cluster mTLS without terminating encryption at the gateway.


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
