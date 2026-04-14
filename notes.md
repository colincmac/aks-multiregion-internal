

# Designing a Private, Multi-Region Global Load Balancer with Open-Source Istio on AKS

This is a great architectural challenge. Tetrate's TSB/TSE products provide this out of the box with their global control plane, but you can absolutely build a comparable **internal-only, multi-region GSLB** using open-source Istio and Azure primitives. Here's a comprehensive design:

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Azure Traffic Manager                         │
│                  (or Azure Front Door – Private Link)                │
│                     DNS-based global routing                         │
│              (Performance / Weighted / Priority profile)             │
└──────────┬──────────────────────────────────┬───────────────────────┘
           │                                  │
    ┌──────▼───────────┐            ┌─────────▼──────────┐
    │  Region: East US │            │  Region: West US   │
    │                  │            │                    │
    │ ┌──────────────┐ │            │ ┌──────────────┐   │
    │ │  Azure ILB   │ │            │ │  Azure ILB   │   │
    │ │ (Private IP) │ │            │ │ (Private IP) │   │
    │ └──────┬───────┘ │            │ └──────┬───────┘   │
    │        │         │            │        │           │
    │ ┌──────▼───────┐ │            │ ┌──────▼───────┐   │
    │ │Istio Ingress │ │            │ │Istio Ingress │   │
    │ │  Gateway     │ │            │ │  Gateway     │   │
    │ │(internal LB) │ │            │ │(internal LB) │   │
    │ └──────┬───────┘ │            │ └──────┬───────┘   │
    │        │         │            │        │           │
    │ ┌──────▼───────┐ │  Mutual    │ ┌──────▼───────┐   │
    │ │  AKS Cluster │◄├──mTLS─────►├─│  AKS Cluster │   │
    │ │  (Istio mesh)│ │  East-West │ │  (Istio mesh)│   │
    │ └──────────────┘ │            │ └──────────────┘   │
    │                  │            │                    │
    │  VNet: 10.1.0.0  │            │  VNet: 10.2.0.0   │
    └──────────────────┘            └────────────────────┘
           │                                  │
           └──────── VNet Peering ────────────┘
                  (or VPN / vWAN)
```

---

## Layer-by-Layer Design

### 1. 🌐 Global Layer — DNS-Based Traffic Distribution

Since everything is **private/internal**, you can't use a traditional public GSLB. Your options:

| Option | Pros | Cons |
|---|---|---|
| **Azure Traffic Manager** (with private endpoints) | Native health probes, performance routing | Requires DNS resolution; health probes come from public IPs (needs workaround) |
| **Azure Private DNS + custom health checks** | Fully private, full control | You build the failover logic yourself |
| **Istio `ServiceEntry` + locality-aware routing** | Pure Istio, no extra infra | Requires cross-cluster Istio mesh (complex) |

**Recommended approach: Hybrid** — Use **Azure Private DNS Zones** for stable internal FQDNs, combined with **Istio locality-aware load balancing** for intelligent routing.

---

### 2. 🔒 Network Layer — Fully Private Connectivity

```bash
# Each region gets its own VNet + AKS with Azure CNI
# VNets are peered for cross-region pod-to-pod communication

# Region 1: East US
az network vnet create --name vnet-east --address-prefix 10.1.0.0/16 ...
az aks create \
  --name aks-east \
  --network-plugin azure \
  --vnet-subnet-id /subscriptions/.../vnet-east/subnets/aks-subnet \
  --enable-private-cluster \
  --load-balancer-sku standard \
  ...

# Region 2: West US
az network vnet create --name vnet-west --address-prefix 10.2.0.0/16 ...
az aks create \
  --name aks-west \
  --network-plugin azure \
  --vnet-subnet-id /subscriptions/.../vnet-west/subnets/aks-subnet \
  --enable-private-cluster \
  --load-balancer-sku standard \
  ...

# Peer the VNets (bidirectional)
az network vnet peering create \
  --name east-to-west \
  --vnet-name vnet-east \
  --remote-vnet /subscriptions/.../vnet-west \
  --allow-vnet-access
```

---

### 3. ⚙️ Istio Layer — Internal Gateways + Multi-Cluster Mesh

This is the core. You have **two architectural choices**:

#### Option A: Multi-Primary Istio Mesh (Recommended)

Each cluster has its own Istio control plane. They share a **common root CA** and discover each other's services via the Istio remote secret mechanism.

```yaml name=istio-operator-east.yaml
# IstioOperator for East US cluster
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: istio-east
spec:
  meshConfig:
    defaultConfig:
      proxyMetadata:
        # Locality is auto-detected from node labels, but can be explicit
        ISTIO_META_REQUESTED_NETWORK_VIEW: "network-east"
    # Enable locality-aware load balancing
    localityLbSetting:
      enabled: true
      failover:
        - from: eastus
          to: westus
  values:
    global:
      meshID: shared-mesh
      multiCluster:
        clusterName: cluster-east
      network: network-east
  components:
    ingressGateways:
      # INTERNAL-ONLY North-South Gateway
      - name: istio-ingressgateway
        enabled: true
        k8s:
          serviceAnnotations:
            # This is the key annotation for internal-only LB on AKS
            service.beta.kubernetes.io/azure-load-balancer-internal: "true"
            service.beta.kubernetes.io/azure-load-balancer-internal-subnet: "ilb-subnet"
          service:
            type: LoadBalancer
            ports:
              - port: 443
                targetPort: 8443
                name: https
              - port: 15443
                targetPort: 15443
                name: tls  # East-West cross-cluster mTLS
      # East-West Gateway for cross-cluster traffic
      - name: istio-eastwestgateway
        enabled: true
        label:
          istio: eastwestgateway
          topology.istio.io/network: network-east
        k8s:
          serviceAnnotations:
            service.beta.kubernetes.io/azure-load-balancer-internal: "true"
          env:
            - name: ISTIO_META_REQUESTED_NETWORK_VIEW
              value: network-east
          service:
            type: LoadBalancer
            ports:
              - name: tls
                port: 15443
                targetPort: 15443
```

#### Cross-Cluster Discovery Setup

```bash
# On each cluster, create a remote secret for the other cluster
# This lets Istiod in East discover services in West, and vice versa

# From East, create a secret for West's API server
istioctl create-remote-secret \
  --context="aks-west" \
  --name=cluster-west | \
  kubectl apply -f - --context="aks-east"

# From West, create a secret for East's API server
istioctl create-remote-secret \
  --context="aks-east" \
  --name=cluster-east | \
  kubectl apply -f - --context="aks-west"
```

> **⚠️ Private Cluster Challenge:** Since these are private AKS clusters, the API server endpoints are private FQDNs. The remote secrets must reference IPs/FQDNs reachable across the peered VNets. You may need **Private DNS Zone forwarding** or to use the API server's private IP directly.

#### Expose Services Cross-Cluster via East-West Gateway

```yaml name=expose-services.yaml
# Apply in BOTH clusters — exposes all mesh services to the other cluster
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: cross-network-gateway
  namespace: istio-system
spec:
  selector:
    istio: eastwestgateway
  servers:
    - port:
        number: 15443
        name: tls
        protocol: TLS
      tls:
        mode: AUTO_PASSTHROUGH  # mTLS passthrough — no termination
      hosts:
        - "*.local"
```

---

### 4. 🎯 Traffic Routing — Locality-Aware Load Balancing

This is where Istio replaces what Tetrate's global control plane does. Istio's **locality-aware routing** uses the Kubernetes node labels (`topology.kubernetes.io/region` and `topology.kubernetes.io/zone`) to prefer local endpoints.

```yaml name=destination-rule-locality.yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: my-api-dr
  namespace: my-app
spec:
  host: my-api.my-app.svc.cluster.local
  trafficPolicy:
    connectionPool:
      http:
        h2UpgradePolicy: DEFAULT
    outlierDetection:
      # REQUIRED for locality failover to work
      consecutive5xxErrors: 3
      interval: 30s
      baseEjectionTime: 30s
      maxEjectionPercent: 100
    loadBalancer:
      localityLbSetting:
        enabled: true
        failover:
          # If East US is unhealthy, fail over to West US
          - from: eastus
            to: westus
          - from: westus
            to: eastus
      simple: ROUND_ROBIN
```

```yaml name=gateway-virtualservice.yaml
# Gateway + VirtualService for north-south ingress (internal clients)
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: internal-api-gateway
  namespace: my-app
spec:
  selector:
    istio: ingressgateway
  servers:
    - port:
        number: 443
        protocol: HTTPS
      tls:
        mode: SIMPLE
        credentialName: internal-api-cert  # Kubernetes secret with TLS cert
      hosts:
        - "api.internal.contoso.com"
---
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: my-api-vs
  namespace: my-app
spec:
  hosts:
    - "api.internal.contoso.com"
  gateways:
    - internal-api-gateway
  http:
    - match:
        - uri:
            prefix: /
      route:
        - destination:
            host: my-api.my-app.svc.cluster.local
            port:
              number: 8080
      retries:
        attempts: 3
        retryOn: 5xx,reset,connect-failure
```

---

### 5. 🏥 Health Checking & Failover

Since Azure Traffic Manager's health probes originate from **public IPs**, and your services are fully private, you need an alternative health signaling mechanism:

```
┌──────────────────────────────────────────────────────┐
│              Health Check Architecture                │
│                                                      │
│  Option 1: Istio Outlier Detection (recommended)     │
│  ─────────────────────────────────────────────────    │
│  Istio's locality failover + outlier detection        │
│  handles this entirely in-mesh. If endpoints in       │
│  region A fail, traffic shifts to region B.           │
│                                                      │
│  Option 2: Azure Private Health Probes               │
│  ─────────────────────────────────────────────────    │
│  Use an Azure Function / small VM in each VNet        │
│  that probes the internal ILB IP and updates          │
│  Azure Private DNS records (active/passive).          │
│                                                      │
│  Option 3: External-DNS + Custom Controller          │
│  ─────────────────────────────────────────────────    │
│  A controller in each cluster watches Istio gateway   │
│  health and updates Azure Private DNS Zone weights.   │
└──────────────────────────────────────────────────────┘
```

**Recommended: Use Istio's built-in outlier detection (Option 1)** — it's the most elegant and requires no external components. The `DestinationRule` above already configures this.

---

### 6. 🔐 Security — Fully Private + mTLS

```yaml name=peer-authentication.yaml
# Enforce STRICT mTLS across the entire mesh
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system
spec:
  mtls:
    mode: STRICT
---
# Shared root CA across clusters — use cert-manager or Vault
# Both clusters must trust the same root CA for cross-cluster mTLS
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: deny-external
  namespace: my-app
spec:
  action: ALLOW
  rules:
    - from:
        - source:
            # Only allow traffic from within the mesh
            principals: ["cluster.local/ns/my-app/sa/*"]
      to:
        - operation:
            methods: ["GET", "POST"]
```

**Shared Root CA** — This is critical for multi-cluster mTLS. Both clusters must share the same root CA so their Istio proxies can authenticate each other:

```bash
# Generate a shared root CA (use Vault, cert-manager, or manual)
# Then configure each Istio installation to use intermediate certs
# signed by this shared root

# Example: plug in custom CA certs before installing Istio
kubectl create secret generic cacerts -n istio-system \
  --from-file=ca-cert.pem \
  --from-file=ca-key.pem \
  --from-file=root-cert.pem \
  --from-file=cert-chain.pem
```

---

### 7. 📡 DNS — Internal Service Discovery

```yaml name=private-dns-setup.sh
# Create Azure Private DNS Zone
az network private-dns zone create \
  --resource-group rg-global \
  --name internal.contoso.com

# Link to both VNets
az network private-dns link vnet create \
  --resource-group rg-global \
  --zone-name internal.contoso.com \
  --name link-east \
  --virtual-network vnet-east \
  --registration-enabled false

az network private-dns link vnet create \
  --resource-group rg-global \
  --zone-name internal.contoso.com \
  --name link-west \
  --virtual-network vnet-west \
  --registration-enabled false

# Add A records pointing to each region's Istio ILB private IP
az network private-dns record-set a add-record \
  --resource-group rg-global \
  --zone-name internal.contoso.com \
  --record-set-name api \
  --ipv4-address 10.1.10.50  # East ILB IP

az network private-dns record-set a add-record \
  --resource-group rg-global \
  --zone-name internal.contoso.com \
  --record-set-name api \
  --ipv4-address 10.2.10.50  # West ILB IP
```

> With both A records, clients get **round-robin DNS**. For smarter routing, use a controller that removes unhealthy region records.

---

## Summary: What Replaces Tetrate TSB/TSE

| Tetrate Feature | Open-Source Replacement |
|---|---|
| Global Control Plane | Multi-primary Istio + remote secrets |
| Global Service Discovery | Istio cross-cluster service discovery via east-west gateways |
| Global Load Balancing | Istio locality-aware LB + `DestinationRule` failover |
| Unified Observability | Kiali + Prometheus federation + Grafana |
| Global Auth Policy | Shared root CA + `PeerAuthentication` + `AuthorizationPolicy` per cluster |
| Management UI | Kiali per cluster (no single pane — this is the biggest gap) |
| DNS-based GSLB | Azure Private DNS Zones + ExternalDNS or custom controller |

## Key Trade-offs vs. Tetrate

1. **No single pane of glass** — You'll manage Istio config per-cluster (mitigate with GitOps/ArgoCD)
2. **Shared root CA management** — You own the PKI lifecycle (use HashiCorp Vault or cert-manager)
3. **Cross-cluster API server access** — Private AKS clusters make remote secrets harder (need DNS forwarding)
4. **Health-based DNS failover** — You must build this yourself (Tetrate handles it natively)

This architecture gives you a fully private, multi-region, globally load-balanced service mesh using only open-source Istio and Azure-native networking. The complexity cost is real, but it's entirely achievable — and avoids vendor lock-in.