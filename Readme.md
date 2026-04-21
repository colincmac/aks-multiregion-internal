# Private Multi-Region Global Load Balancing with Istio Sidecar Mode on AKS

A fully private, multi-region service mesh architecture using **Istio (traditional sidecar mode)** on Azure Kubernetes Service (AKS), managed via **Flux GitOps**. Deploy any number of private AKS clusters across Azure regions — the infrastructure automatically creates full-mesh VNet peering, Flux GitOps, and Private DNS linking between all clusters. Istio sidecar proxies provide mTLS, L4/L7 policy enforcement, and locality-aware load balancing with cross-region failover.

[![Deploy to Azure](https://aka.ms/deploytoazure)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fcolincmac%2Faks-multiregion-internal%2Fmain%2Finfra%2Fmain.bicep)
[![Deploy to Azure Gov](https://aka.ms/deploytoazuregovbutton)](https://portal.azure.us/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fcolincmac%2Faks-multiregion-internal%2Fmain%2Finfra%2Fmain.bicep)

> **CNI Note:** AKS uses Azure Overlay CNI with Cilium dataplane. Cilium handles all pod networking, so `istio-cni` is **not needed** and is kept commented out in the Kustomization. Sidecar injection is enabled via `istio-injection: enabled` namespace labels.

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
 │  │ (Istio     │  │   │  │ (Istio     │  │   │  │ (Istio     │  │
 │  │  sidecars) │  │   │  │  sidecars) │  │   │  │  sidecars) │  │
 │  └────────────┘  │   │  └────────────┘  │   │  └────────────┘  │
 │  VNet: 10.1.0/16 │   │  VNet: 10.2.0/16 │   │  VNet: 10.N.0/16 │
 └──────────────────┘   └──────────────────┘   └──────────────────┘
          │                       │                      │
          └─── mTLS (15443 TLS AUTO_PASSTHROUGH) E-W ───┘
          │                                              │
          └───── Full-Mesh VNet Peering ─────────────────┘
```

**How traffic flows:**

1. Internal clients resolve `api.internal.contoso.com` via Azure Private DNS, which returns ILB IPs for all regions (round-robin).
2. Requests hit the region-local Kubernetes Gateway API `Gateway` resource (Istio gateway class), backed by an internal Azure load balancer.
3. Istio sidecar mode routes to local pods by default using **locality-aware load balancing** with `failoverPriority: [topology.istio.io/cluster]`.
4. L7 policy (outlier detection, locality failover) is enforced by the **sidecar proxies** in each pod.
5. If local endpoints fail health checks (3 consecutive 5xx errors trigger outlier detection), the sidecar proxy automatically fails over to healthy instances in another cluster via **east-west gateways** over mTLS on port 15443 (TLS AUTO_PASSTHROUGH).

## Failover Scenarios

This solution handles three distinct failure scenarios:

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

### Scenario 4 — Gateway Failure with Healthy Workloads (two-tier DNS GSLB)
**The tiered gateway failure gap**: the ingress gateway itself is down (crashed, misconfigured, or out of IPs) but the workload pods are fine. The backend probe alone would report healthy → DNS stays registered → clients hit the dead gateway.

The health-check controller uses a **two-tier GSLB probe** to close this gap:
1. **Tier 1 (backend)**: Probes `my-api.my-app.svc.cluster.local:8080` directly — detects workload failures
2. **Tier 2 (gateway)**: Probes `istio-ingressgateway.istio-system.svc.cluster.local:15021/healthz/ready` — detects gateway failures

DNS is only registered when **both** tiers are healthy. If either tier fails, DNS is deregistered and clients fail over to a healthy region. This mirrors the [Tetrate tier1/tier2 edge failover pattern](https://docs.tetrate.io/service-bridge/getting-started/use-cases/tier1-tier2/edge-failover): health checks at every tier of the data path ensure that a failure anywhere between the client and the workload causes DNS-level failover.

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
                   │  Two-tier GSLB:   │   │  Two-tier GSLB:   │
                   │  ┌─────────────┐  │   │  ┌─────────────┐  │
                   │  │Tier 1: probe│  │   │  │Tier 1: probe│  │
                   │  │  my-api     │  │   │  │  my-api     │  │
                   │  │  directly   │  │   │  │  directly   │  │
                   │  └──────┬──────┘  │   │  └──────┬──────┘  │
                   │  ┌─────────────┐  │   │  ┌─────────────┐  │
                   │  │Tier 2: probe│  │   │  │Tier 2: probe│  │
                   │  │  ingress    │  │   │  │  ingress    │  │
                   │  │  gateway    │  │   │  │  gateway    │  │
                   │  │  :15021     │  │   │  │  :15021     │  │
                   │  └──────┬──────┘  │   │  └──────┬──────┘  │
                   │  both OK│         │   │  both OK│         │
                   │  → keep │Service  │   │  → keep │Service  │
                   │  either fails     │   │  either fails     │
                   │  → delete│Service │   │  → delete│Service │
                   └──────────┴────────┘   └──────────┴────────┘
                        East Cluster             West Cluster
```

**Key design properties:**
- **Per-cluster ownership**: Each ExternalDNS uses a unique `--txt-owner-id` (`cluster-east` / `cluster-west`) so each instance only manages its own A record contribution
- **Two-tier health**: Both the backend workload AND the ingress gateway must be healthy before DNS is registered
- **Fast failover**: TTL=30s + probe interval=5s + fail threshold=3 + ExternalDNS poll interval=10s = ~55s worst-case
- **Automatic recovery**: Controller recreates the DNS Service when both tiers recover; ExternalDNS re-adds the A record
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
│   │   ├── istio-system/           # Shared: namespace, PeerAuthentication,
│   │   │                           #   HelmRelease for istio/base (istio-cni commented out)
│   │   ├── istio-egress/           # Egress gateway namespace + Gateway resource
│   │   ├── my-app/                 # DestinationRule, K8s Gateway, HTTPRoute,
│   │   │                           #   AuthorizationPolicy, ServiceEntry, Service
│   │   ├── health-check/           # Health-check controller (Scenario 3+4 detection)
│   │   │   ├── namespace.yaml      #   Namespace with sidecar injection
│   │   │   ├── serviceaccount.yaml #   ServiceAccount for RBAC
│   │   │   ├── role.yaml           #   Roles: manage Services + read Endpoints
│   │   │   ├── rolebinding.yaml    #   RoleBindings
│   │   │   ├── configmap.yaml      #   Controller script (two-tier probe) + dns-service.yaml template
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
│   │   ├── helmrelease-istiod.yaml # istiod with cluster-east sidecar config
│   │   ├── helmrelease-eastwestgateway.yaml # East-west gateway (TLS AUTO_PASSTHROUGH/15443)
│   │   ├── cross-network-gateway.yaml      # Istio Gateway for cross-network traffic
│   │   ├── istio-system-patch.yaml # topology.istio.io/network label patch
│   │   ├── externaldns-patch.yaml  # --txt-owner-id=cluster-east patch
│   │   └── kustomization.yaml
│   └── west/                       # West cluster overlay (mirror of east)
│       ├── helmrelease-istiod.yaml
│       ├── helmrelease-eastwestgateway.yaml
│       ├── cross-network-gateway.yaml
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
| **AKS Clusters** | N private clusters (any Azure regions) with Azure Overlay CNI + Cilium dataplane, availability zones, system + autoscaling user node pools, OIDC issuer + Workload Identity enabled |
| **Networking** | Dedicated VNet per cluster with AKS and ILB subnets, automatic full-mesh VNet peering |
| **GitOps** | Flux v2 extension on each cluster, syncing per-region Kustomize manifests from this repo |
| **Service Mesh** | Multi-primary Istio **sidecar mode** — each cluster runs its own control plane (istiod); sidecars injected via `istio-injection: enabled` namespace labels |
| **mTLS** | STRICT mode mesh-wide via PeerAuthentication; cross-cluster mTLS via shared root CA and east-west gateways (TLS AUTO_PASSTHROUGH on port 15443) |
| **L7 Policy** | Sidecar proxies enforce outlier detection, locality failover, and AuthorizationPolicies — no waypoint proxies needed |
| **Load Balancing** | Locality-aware routing with `failoverPriority: [topology.istio.io/cluster]`; outlier detection: 3 consecutive 5xx errors → failover |
| **Ingress** | Kubernetes Gateway API (`gateway.networking.k8s.io/v1`) with `gatewayClassName: istio`, backed by internal Azure LBs |
| **DNS** | Azure Private DNS Zone linked to all cluster VNets; A records managed dynamically by ExternalDNS |
| **Health-Check Controller** | Per-cluster controller with **two-tier GSLB probes** (backend + gateway); deletes DNS Service on failure for Scenarios 3+4 |
| **ExternalDNS** | Per-cluster ExternalDNS with Azure Private DNS provider; watches annotated Services and maintains A records with per-cluster TXT ownership |
| **Workload Identity** | Per-cluster User-Assigned Managed Identity for ExternalDNS with Private DNS Zone Contributor role and federated credential |

## Prerequisites

- Azure CLI with Bicep
- An Azure subscription with permissions to create resources at subscription scope
- A GitHub repository for Flux to pull Kustomize manifests from

## Deployment

Three deployment paths are supported: the **Azure Portal button** (quickstart), the **Azure Developer CLI** (`azd`), and **GitHub Actions** (CI/CD). All three use the same Bicep template under `infra/`.

### Option A — Deploy to Azure (Portal button)

Click the button at the top of this README or use the link below. The Azure portal opens a custom deployment form pre-loaded with `infra/main.bicep`. Fill in the required parameters (environment name, cluster definitions) and click **Review + create**.

> **Note:** The portal form requires the `clusters` parameter to be entered as a JSON array. Use the values from `infra/main.bicepparam` as a starting point and adjust regions/prefixes as needed.

### Option B — Azure Developer CLI (`azd`)

The [Azure Developer CLI](https://aka.ms/azd) provides a guided, interactive deployment experience from your local machine.

#### Prerequisites

- [Azure Developer CLI ≥ 1.9](https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd)
- Azure CLI with Bicep extension

#### Steps

```bash
# 1. Authenticate
azd auth login

# 2. Initialize the environment (prompts for environment name and region)
azd env new <env-name>
azd env set AZURE_LOCATION eastus

# 3. (Optional) Override the Flux Git URL and DNS zone name
azd env set GIT_REPOSITORY_URL  "https://github.com/<org>/<repo>"
azd env set PRIVATE_DNS_ZONE_NAME "internal.contoso.com"

# 4. Edit infra/main.bicepparam to customize the clusters array, then deploy
azd provision
```

`azd provision` runs `az deployment sub create` with `infra/main.bicep` and `infra/main.bicepparam`. Environment variables set via `azd env set` are automatically injected as `readEnvironmentVariable()` values in the parameter file.

### Option C — GitHub Actions (CI/CD)

The included workflow (`.github/workflows/deploy-infrastructure.yml`) provides:

- **PR validation** — runs `az deployment sub validate` on every pull request that touches `infra/`.
- **What-if** — shows a diff of planned changes before applying them.
- **Manual deploy** — triggered via `workflow_dispatch` with inputs for environment name, location, and a what-if toggle.

#### Setting up OIDC credentials

The workflow authenticates to Azure using OpenID Connect (no stored secrets). Create a federated credential on an Entra ID app or managed identity, then add three repository secrets:

| Secret | Value |
|---|---|
| `AZURE_CLIENT_ID` | Application (client) ID of the Entra ID app |
| `AZURE_TENANT_ID` | Directory (tenant) ID |
| `AZURE_SUBSCRIPTION_ID` | Target subscription ID |

Grant the app the **Contributor** + **User Access Administrator** roles at subscription scope (required to create resource groups and role assignments).

```bash
# Create a service principal with federated credentials for GitHub Actions
az ad app create --display-name "aks-multiregion-deploy"
APP_ID=$(az ad app list --display-name "aks-multiregion-deploy" --query "[0].appId" -o tsv)
SP_OID=$(az ad sp create --id "$APP_ID" --query id -o tsv)

az role assignment create \
  --assignee-object-id "$SP_OID" \
  --role "Contributor" \
  --scope "/subscriptions/<subscription-id>"

az role assignment create \
  --assignee-object-id "$SP_OID" \
  --role "User Access Administrator" \
  --scope "/subscriptions/<subscription-id>"

# Federated credential for GitHub Actions
az ad app federated-credential create \
  --id "$APP_ID" \
  --parameters '{
    "name": "github-actions",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:colincmac/aks-multiregion-internal:ref:refs/heads/main",
    "audiences": ["api://AzureADTokenExchange"]
  }'
```

Then add `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and `AZURE_SUBSCRIPTION_ID` as repository secrets.

#### Triggering a deployment

Go to **Actions → Deploy Infrastructure → Run workflow**, enter your environment name and location, and click **Run workflow**. Uncheck *what-if* to apply the changes.

---

### Manual Deployment (PowerShell)

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
    bastionSubnetPrefix: '10.1.17.0/26'
    utilityVMSubnetPrefix: '10.1.18.0/28'
    kustomizationPath: './clusters/east'
  }
  {
    name: 'centralus'
    location: 'centralus'
    addressPrefix: '10.2.0.0/16'
    aksSubnetPrefix: '10.2.0.0/20'
    ilbSubnetPrefix: '10.2.16.0/24'
    bastionSubnetPrefix: '10.2.17.0/26'
    utilityVMSubnetPrefix: '10.2.18.0/28'
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

This step is now automated. The Bicep deployment still creates the
User-Assigned Managed Identity for ExternalDNS and grants it `Private DNS Zone Contributor`, but the repository overlays are patched automatically with the concrete client IDs and Azure subscription values:

- `scripts/deploy.ps1` runs the sync automatically after `az deployment sub create`
- `azd provision` runs the same sync through the `postprovision` hook in `azure.yaml`

If you reprovision the infrastructure and want to refresh the GitOps source of truth manually, run:

```powershell
./scripts/sync-gitops-config.ps1
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

# Check sidecar injection is active
kubectl get pods -n my-app --context=aks-eastus2
# Each pod should have 2 containers (app + istio-proxy sidecar)

# Verify east-west gateway is running
kubectl get pods -n istio-system -l istio=eastwestgateway --context=aks-eastus2

# Verify Istio sees endpoints across clusters
istioctl proxy-config endpoints <my-app-pod> -n my-app --context=aks-eastus2 | grep my-api

# Verify health-check controller is running (if enabled)
kubectl get pods -n health-check --context=aks-eastus2
kubectl logs -n health-check -l app=health-check-controller --context=aks-eastus2
```

## Key Design Decisions

- **Sidecar mode (not ambient)** — Each pod gets an `istio-proxy` sidecar injected via `istio-injection: enabled` namespace labels. No ztunnel or waypoint proxies needed. Rationale: [`docs/adr/0003-sidecar-vs-ambient.md`](docs/adr/0003-sidecar-vs-ambient.md).
- **Cilium CNI — no istio-cni** — AKS uses Azure Overlay CNI with Cilium dataplane. Cilium handles all pod networking; `istio-cni` is not required and is kept commented out. Rationale: [`docs/adr/0002-cni-choice.md`](docs/adr/0002-cni-choice.md).
- **TLS AUTO_PASSTHROUGH east-west** — Cross-cluster traffic uses the classic Istio east-west gateway pattern: TLS passthrough on port 15443 with `ISTIO_META_ROUTER_MODE: sni-dnat`. Each cluster has its own `istio-eastwestgateway` Helm release.
- **Kubernetes Gateway API** — North-south ingress uses `gateway.networking.k8s.io/v1` `Gateway` + `HTTPRoute` instead of the legacy Istio `Gateway`/`VirtualService` API. Both work with sidecar mode.
- **Two-tier DNS GSLB** — The health-check controller probes both the backend workload (`my-api:8080`) AND the ingress gateway (`istio-ingressgateway:15021/healthz/ready`). DNS is only registered when both tiers are healthy. This closes the tiered gateway failure gap that a workload-only probe misses. TTL / probe cadence rationale: [`docs/adr/0004-gslb-ttl-and-probe-cadence.md`](docs/adr/0004-gslb-ttl-and-probe-cadence.md). Replacing DNS-only GSLB with a real Tier-1 gateway is pending decision: [`docs/adr/0001-tier1-gateway-choice.md`](docs/adr/0001-tier1-gateway-choice.md).
- **Flux HelmRelease for Istio** — No `helm install` or `istioctl install` commands. The Helm charts (base → istiod → eastwestgateway) are installed in dependency order by Flux.
- **N-cluster scalability** — Define clusters in a single parameter array. VNet peering, DNS linking, and Flux configuration scale automatically.
- **Multi-primary mesh** — Each cluster operates independently; no single point of failure for the control plane.
- **Fully private** — No public IPs. All load balancers use `service.beta.kubernetes.io/azure-load-balancer-internal: "true"`, clusters use private API server endpoints, and DNS is via Azure Private DNS Zones.
- **Shared root CA** — All clusters trust the same root certificate authority, enabling cross-cluster mTLS without terminating encryption at the gateway. Rotation procedure: [`docs/runbooks/ca-rotation.md`](docs/runbooks/ca-rotation.md).

## Enterprise-readiness

- **Demo app** — `clusters/base/my-app/` now ships a real podinfo-based frontend (`my-api`) + backend (`my-api-backend`), with HPA, PDBs, PSA-`restricted` security contexts, per-cluster UI-message patches so responses clearly show which region served the request, and an optional `demo-traffic/` overlay with retries/canary/mirror/fault-injection/sticky-hash/cross-region-weighted examples.
- **Default-deny zero-trust baseline** — `clusters/base/istio-system/authorization-policy-default-deny.yaml` installs a mesh-wide default-deny AuthorizationPolicy; per-namespace ALLOW policies whitelist each flow. Rationale: [`docs/adr/0005-default-deny-authz.md`](docs/adr/0005-default-deny-authz.md).
- **Defense in depth** — Istio AuthorizationPolicies (L7) are layered with Kubernetes NetworkPolicies (L3/L4, enforced by Cilium).
- **Documentation** — see [`docs/`](docs/) for ADRs, runbooks, threat model, and cost model.

### Still-open work (tracked as ADRs / runbooks)

| Area | Status | Where |
|---|---|---|
| Tier-1 gateway choice (dedicated AKS vs. Front Door vs. AppGw + X-region LB) | **Decision pending** | [`docs/adr/0001-tier1-gateway-choice.md`](docs/adr/0001-tier1-gateway-choice.md) |
| Observability bundle (Azure Managed Prometheus + Grafana, Kiali, Jaeger) | Not started | separate PR |
| cert-manager + Azure Key Vault issuer for intermediate CAs | Not started | separate PR; [`docs/runbooks/ca-rotation.md`](docs/runbooks/ca-rotation.md) describes the target state |
| Health-check controller → Go controller-runtime operator with `MeshHealthCheck` CRD | Not started | separate PR |
| GitOps-only post-deploy (External Secrets Operator, Flux-managed remote secrets) | Not started | separate PR |
| Kyverno / Gatekeeper + cosign/ratify policies | Not started | separate PR |
| Revisioned istiod canary-upgrade automation | Runbook only | [`docs/runbooks/istiod-canary-upgrade.md`](docs/runbooks/istiod-canary-upgrade.md) |
| Azure Chaos Studio experiments + PR-gated CI | Not started | separate PR |
| Azure PaaS active-active downstream demo (Cosmos DB, Service Bus) | Not started | separate PR |
