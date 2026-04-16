# ADR-0001 — Tier-1 gateway choice

- **Status:** Proposed — decision required
- **Deciders:** Platform architecture team
- **Date:** _unreleased_

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

## Decision

_**To be made.**_ Recommended default for "fully private + enterprise
policy" is **Option A** (dedicated Istio Tier-1 cluster(s)). If a public
edge is acceptable, **Option B** is simpler. Option C is a reasonable
middle ground when AppGw-WAF is already a corporate standard.

## Consequences

- Option A: introduces new Bicep modules for the Tier-1 cluster(s), a new
  Flux overlay (`clusters/tier1-*`), and a new Istio trust/mesh-topology
  plane between Tier-1 and Tier-2.
- Option B: introduces new Bicep modules for Front Door + Private Link
  services on the Tier-2 ingress; DNS GSLB is replaced by Front Door's
  backend health probes and routing rules.
- Option C: introduces AppGw + WAF policy modules per region and a
  Traffic Manager or cross-region LB profile.
- Any of A/B/C supersedes the current DNS-based GSLB and should update the
  health-check controller to become Tier-aware (see ADR-0004 and the
  Phase 6 Go-operator work).

## Follow-ups

1. Pick an option (record here when decided).
2. Create `infra/modules/tier1-*.bicep` and `clusters/tier1-*/` as appropriate.
3. Update `docs/runbooks/region-failover.md` to include Tier-1-level steps.
4. Extend the health-check controller with a Tier-1 probe.
