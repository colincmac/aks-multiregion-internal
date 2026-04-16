# ADR-0005 — Mesh-wide default-deny AuthorizationPolicy baseline

- **Status:** Accepted
- **Date:** this PR

## Context

Istio's default behavior is "allow all" mTLS traffic once
`PeerAuthentication` STRICT is applied: identities are proven, but any
authenticated identity can reach any service. For an enterprise baseline
that should be inverted to "deny unless explicitly allowed".

## Decision

Install an `AuthorizationPolicy` named `default-deny-all` in the root
namespace (`istio-system`) with an empty spec. Istio applies this
policy to every workload in the mesh. Because the policy has no `action`
and no `rules`, it acts as an implicit deny fallback; per-namespace
`ALLOW` policies are layered on top to whitelist specific flows.

Per-namespace defense-in-depth:

- `clusters/base/my-app/authorization-policy.yaml` contains a
  namespace-local `default-deny` plus explicit allows for:
  - the Istio ingress gateway → `my-api`
  - `my-api` → `my-api-backend`
  - Prometheus scraping (metrics ports only)
- `clusters/base/my-app/network-policy.yaml` adds L3/L4 equivalents
  (see ADR-0002 for CNI enforcement).

## Consequences

- Any new workload or flow must be accompanied by an explicit
  `AuthorizationPolicy` (and typically a `NetworkPolicy`). This is
  intentional friction — it forces deliberate security review.
- Introducing a new cross-namespace caller requires knowing its SPIFFE
  principal: `cluster.local/ns/<NS>/sa/<SA>`.
- Incident recovery: if an AllowPolicy is accidentally deleted during an
  outage, traffic for that flow stops. The runbook
  [`docs/runbooks/region-failover.md`](../runbooks/region-failover.md)
  mentions this as a known rollback checklist item.

## Alternatives considered

- **Audit-only default policy**: rejected — the Istio 1.29 `AUDIT`
  action does not cause denial and can lull teams into shipping
  unauthorized flows.
- **Per-namespace default-deny only** (no mesh-wide policy): rejected —
  new namespaces would be open by default until a policy is added.
