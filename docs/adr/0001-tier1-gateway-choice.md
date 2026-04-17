# ADR-0001 — Tier-1 gateway choice

- **Status:** Accepted — Option E (AGC per region) + future Azure Private
  Traffic Manager
- **Deciders:** Platform architecture team
- **Date:** 2026-04-16

## Context

The current solution uses DNS round-robin over an Azure Private DNS zone,
toggled by a per-cluster health-check controller, as a "poor-man's Tier-1
GSLB". This works but has meaningful limits:

- Minimum practical failover time is ~55s (TTL + probe interval + ExternalDNS
  poll).
- Long-lived clients can cache DNS for far longer than the zone TTL.
- DNS cannot do L7 routing (headers, paths, JWT claims) across regions.
- DNS cannot do weighted traffic shifting, blue/green, or canary across
  regions.
- No edge-level policy (JWT, rate limit, WAF, mutual TLS auth to tenants).
- Health-check controller only probes Tier-2 + workload; it cannot detect
  Tier-1 issues because Tier-1 does not exist.

The reference Tetrate pattern uses an explicit Tier-1 gateway that performs
L7 global routing and is itself health-checked.

## Options considered

### A. Dedicated Istio Tier-1 cluster(s) (private AKS)

- Dedicated, small AKS cluster per region running only the Istio Tier-1
  gateway, fronted by an Azure cross-region internal Load Balancer or
  Traffic Manager internal endpoints.
- Tier-1 routes to regional Tier-2 gateways via mTLS using either a second
  east-west plane or `ServiceEntry` + remote secrets.
- Full L7 policy, JWT auth, locality-weighted routing, header-based canary.

**Pros**
- Matches Tetrate model exactly.
- Fully private.
- Uses the mesh identity (SPIFFE) all the way to the edge.
- Transparent to existing Tier-2 config.

**Cons**
- Extra AKS cluster(s) to operate and upgrade.
- More Istio revisions to track.
- Cross-region internal LB has specific SKU / region constraints to verify.

### B. Azure Front Door Premium + Private Link origins

- Front Door is public-facing; Private Link origins keep the backends
  private.
- Natural fit if the product is ever exposed to the public internet.
- Built-in WAF, rate-limit, bot protection, TLS cert management, global
  anycast IPs.

**Pros**
- Managed service, no cluster to run.
- Mature WAF and DDoS protection.
- Global edge for latency.

**Cons**
- Public-entry by design; conflicts with the current "fully private"
  posture unless policy allows it.
- Regional routing is constrained to Front Door's feature set (weights,
  latency, session affinity); less flexible than Istio L7.
- Does not carry SPIFFE identity — edge-to-origin trust is a separate
  mTLS concern.

### C. Azure Application Gateway v2 per region + Traffic Manager / cross-region LB

- Regional AppGw with WAF.
- Traffic Manager or Azure cross-region LB aggregates regions.

**Pros**
- Fully private if Private AppGw is used.
- WAF included.
- No new AKS cluster.

**Cons**
- Traffic Manager is DNS-based with the same TTL issues as today.
- Cross-region LB (preview/GA status depends on region) has anycast
  routing but limited L7 policy.
- Splits policy across AppGw + Istio; two config surfaces.

### D. Keep DNS-only GSLB (do nothing)

- Accept the 55s failover and lack of L7 global routing.
- Invest instead in faster client-side retries and region-aware SDKs.

**Pros**
- Zero new infrastructure.

**Cons**
- Does not close the gaps identified in the evaluation.

### E. Azure Application Gateway for Containers (AGC) per region + future Azure Private Traffic Manager

- One AGC instance per region (BYO-deployment mode, private frontend IP in
  a delegated subnet of each regional VNet), fronting the regional Istio
  Tier-2 ingress gateway over backend mTLS (`BackendTLSPolicy`).
- Gateway API (`Gateway` + `HTTPRoute`) configuration is reconciled from
  the cluster by the Application Load Balancer (ALB) Controller, so L7
  policy lives next to the workloads in Git.
- Cross-region DNS GSLB is still provided today by the existing
  ExternalDNS + health-check controller pattern (ADR-0004), but the
  A-record targets switch from Tier-2 ILBs to AGC private frontend IPs.
  When Azure Private Traffic Manager GAs, the DNS layer is replaced by
  a Private Traffic Manager profile whose endpoints are the same AGC
  private IPs — a single-layer swap with no change to Tier-1, Tier-2,
  or application config.

**Pros**
- Fully private (private frontend IP only; no public entry).
- Managed L7 data plane — no extra AKS cluster to patch, upgrade, or
  scale (directly addresses the main Option A operational cost).
- Gateway API native: host/path/header routing, weighted traffic
  splitting for canary/blue-green, backend mTLS via `BackendTLSPolicy`,
  custom health probes on Tier-2.
- Integrated WAF policy at Tier-1.
- Stable per-region private IP == the exact endpoint shape Azure Private
  Traffic Manager will consume, making the future GSLB migration a
  DNS-only change.
- Keeps the Istio mesh boundary at Tier-2, so existing `VirtualService`,
  `AuthorizationPolicy`, and `RequestAuthentication` remain authoritative
  for in-mesh policy.

**Cons**
- SPIFFE mesh identity does not extend to the edge — AGC terminates
  client TLS and re-originates mTLS to Tier-2 using a cert-based trust
  chain, not a mesh-issued SPIFFE identity. Acceptable here because
  Tier-1 is inside the corporate network; in-mesh identity resumes at
  Tier-2.
- JWT validation / fine-grained authz is not native to AGC and stays at
  Tier-2 (Istio `RequestAuthentication` + `AuthorizationPolicy`).
  Unauthenticated traffic therefore reaches the Tier-2 gateway before
  being rejected; acceptable given private-only entry.
- Two config surfaces (Gateway API at Tier-1, Istio CRDs at Tier-2), but
  each surface is scoped to the layer that owns the concern.
- AGC region availability and subnet-delegation prerequisites must be
  verified per region at deploy time.

## Decision

**Option E** — one Application Gateway for Containers per region as the
Tier-1 L7 gateway, with the existing DNS-based GSLB retained as the
cross-region layer until Azure Private Traffic Manager is generally
available, at which point the DNS layer is replaced by a Private Traffic
Manager profile pointing at the AGC private frontend IPs.

### Rationale

1. **Fully private today.** AGC supports a private-only frontend IP in a
   delegated subnet, satisfying the "no public entry" posture that rules
   out Option B.
2. **Clean migration path to Azure Private Traffic Manager.** Because
   Private Traffic Manager is DNS-based private GSLB, it only replaces
   the *cross-region DNS* layer, not the L7 Tier-1. AGC's stable
   per-region private IP is exactly the endpoint shape Private Traffic
   Manager will consume, so the migration is a DNS-layer swap with zero
   changes at Tier-1 or Tier-2. This was the user-stated primary
   constraint.
3. **Lower operational cost than Option A.** No additional AKS cluster
   per region to build, patch, upgrade, and monitor. Istio revisions
   remain scoped to the Tier-2 clusters.
4. **L7 capabilities that DNS-only GSLB (including Private Traffic
   Manager) cannot provide**: header/path routing, weighted canary,
   backend mTLS, WAF.
5. **Option C (AppGw v2 + Traffic Manager)** was considered close but
   rejected because it still relies on public-DNS Traffic Manager (same
   TTL limitations as today) and does not give us Gateway-API-native
   weighted routing. Option E supersedes Option C.
6. **Option D** does not close the gaps identified in the evaluation.

### Scope of this decision

- Tier-1 = AGC per region (new).
- Tier-2 = unchanged (Istio ingress gateway inside each regional AKS
  cluster).
- Cross-region GSLB = existing ExternalDNS + health-check controller
  against the Private DNS zone (ADR-0004), retargeted from Tier-2 ILBs
  to AGC private frontend IPs.
- Future: replace the DNS GSLB layer with Azure Private Traffic Manager
  when GA, endpoints = same AGC private IPs. Tracked as a follow-up,
  not part of this ADR.

## Consequences

- Introduces a new Bicep module `infra/modules/tier1-agc.bicep` that
  provisions per region: the ALB-delegated subnet, the AGC parent
  resource (BYO-deployment), the association with the VNet, the
  user-assigned managed identity for the ALB Controller, and the
  private frontend configuration. A scaffold of this module lands in
  this change and is wired into `infra/main.bicep` in a follow-up PR
  once subnet prefixes are allocated per region.
- Introduces a new Flux overlay `clusters/base/tier1-agc/` containing
  the Gateway API `Gateway`, `HTTPRoute` to the Tier-2 Istio ingress
  gateway, and `BackendTLSPolicy` for backend mTLS. Regional
  kustomizations (`clusters/east`, `clusters/west`) opt in to this
  overlay in a follow-up once the ALB Controller is installed in each
  cluster.
- The ExternalDNS + health-check controller (ADR-0004) continues to own
  the DNS GSLB record but its probe targets and A-record values switch
  from Tier-2 ILB IPs to AGC private frontend IPs. The health-check
  controller also gains a Tier-1 probe so AGC-level outages are
  detected independently of Tier-2 health.
- When Azure Private Traffic Manager reaches GA, a separate ADR will
  record the replacement of the DNS-based GSLB layer; no changes to
  Tier-1 or Tier-2 are expected at that time.
- Istio `AuthorizationPolicy` and `RequestAuthentication` remain the
  authoritative edge-of-mesh policy at Tier-2. Tier-1 is responsible
  for transport, L7 routing, WAF, and health-based region selection.

## Follow-ups

1. **(done in this change)** Record the decision on this ADR.
2. **(scaffold in this change)** Add `infra/modules/tier1-agc.bicep` and
   `clusters/base/tier1-agc/`.
3. Allocate an AGC-delegated subnet prefix per regional VNet in
   `infra/modules/vnet.bicep` and `main.example.bicepparam`, then wire
   `tier1-agc.bicep` into `infra/main.bicep`.
4. Install the ALB Controller (Helm) into each regional AKS cluster and
   opt the regional kustomizations (`clusters/east`, `clusters/west`)
   into `../base/tier1-agc`.
5. Repoint the ExternalDNS `Service` in the health-check controller
   from the Tier-2 ILB to the AGC private frontend IP; add a Tier-1
   probe per ADR-0004.
6. Update `docs/runbooks/region-failover.md` with Tier-1 AGC
   verification and override steps (initial note added in this change).
7. When Azure Private Traffic Manager GAs, open a new ADR recording the
   DNS-layer replacement.
