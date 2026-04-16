# Threat model (STRIDE) — AKS multi-region private mesh

This is a **starting-point** threat model for the platform. It will not
cover application-specific threats; each service team should extend it
with its own data-flow diagrams.

## Trust boundaries

1. **Client → Tier-1 (future) / Tier-2 (today)** — DNS-resolvable
   endpoint inside the corporate network. TLS terminates here.
2. **Tier-2 gateway → sidecar** — inside the cluster, mTLS via SPIFFE.
3. **Sidecar → east-west gateway → remote cluster sidecar** — mTLS over
   port 15443, SPIFFE identity preserved end-to-end.
4. **Sidecar → mesh-external services** — egress gateway; outbound to
   public internet or Azure PaaS.
5. **Control plane → Kubernetes API / Azure control plane** — Workload
   Identity (Azure AD federated) and Kubelet cert.
6. **GitOps source → Flux → cluster** — Git commits signed + Flux pulls
   over HTTPS.

## STRIDE summary

| Threat | Asset | Mitigation today | Gap / follow-up |
|---|---|---|---|
| **S**poofing identity | Cross-cluster sidecar-to-sidecar | mTLS STRICT via shared root CA; SPIFFE principal names in AuthZ | Key Vault-backed root CA with HSM (ADR pending) |
| **S**poofing DNS | `api.internal.contoso.com` | Azure Private DNS (authenticated management plane), TXT owner records | Tier-1 endpoint + client-pinned cert would remove DNS-spoof relevance |
| **T**ampering in transit | Any in-mesh hop | mTLS STRICT + default-deny AuthZ | Add mesh-wide default-deny on every new cluster |
| **T**ampering at rest | Git manifests | GitHub branch protection + PR review (relies on org config) | Enforce signed commits; enable GitHub CODEOWNERS |
| **R**epudiation | API calls | Istio access logs → `/dev/stdout` | Ship logs to Azure Monitor / Sentinel; retention policy |
| **I**nformation disclosure | `cacerts` / remote secret / `external-dns-azure` secret | RBAC scoped to `istio-system` / `external-dns` | Move to External Secrets Operator + Key Vault (ADR pending) |
| **I**nformation disclosure | Pod-to-pod traffic | mTLS STRICT + NetworkPolicy | Add egress NetworkPolicy allow-list (today egress is open) |
| **D**enial of service | Tier-2 ingress | `outlierDetection`, connection-pool limits, HPA | Add global rate-limit at Tier-1 once ADR-0001 resolves |
| **D**enial of service | `istiod` | Revisioned canary upgrade; Flux drift-detect | Add resource requests/limits baseline to HelmRelease values |
| **E**levation of privilege | Sidecar init (NET_ADMIN) | PSA-restricted on app namespaces; Istio injection scope | Evaluate istio-cni to remove NET_ADMIN from pods |
| **E**levation of privilege | Flux impersonation | Flux uses cluster-admin by default | Switch to per-namespace Kustomization service accounts |
| **E**levation of privilege | ExternalDNS Workload Identity | UAMI scoped to Private DNS Zone Contributor on ONE zone | Review Azure RBAC annually |

## Known residual risks

- **DNS-only GSLB** lets attackers with LAN access probe each region's
  ILB independently. Closed once Tier-1 lands.
- **Manual `cacerts` / remote-secret steps** during onboarding create a
  window during which the cluster has self-signed CA material.
  ADR-pending item: GitOps-only bootstrap.
- **Egress open by default** — NetworkPolicy today denies namespace
  ingress but does not restrict egress. For regulated environments,
  add egress allow-lists (Istio `ServiceEntry` + CNI egress policies).

## Re-review cadence

Quarterly, or whenever:
- A new Tier (edge gateway, new cluster) is added.
- Istio minor version upgrades.
- New downstream pattern (Cosmos DB, Service Bus, new SaaS) is onboarded.
