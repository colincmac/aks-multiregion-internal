# ADR-0003 — Sidecar mode vs. Istio ambient

- **Status:** Accepted (sidecar mode); ambient tracked as future work
- **Date:** initial deployment

## Context

Istio offers two data-plane modes:

- **Sidecar mode** — every pod gets an `istio-proxy` injected. Mature,
  L4+L7 policy per pod, full feature set.
- **Ambient mode** — per-node `ztunnel` provides L4 mTLS; optional
  per-namespace or per-service `waypoint` proxies add L7. Reduces
  per-pod memory overhead and the "every workload needs a sidecar"
  friction, at the cost of being newer with narrower feature parity.

## Decision

Use **sidecar mode** for now.

## Rationale

- Multi-primary multi-cluster on port 15443 with
  `TLS AUTO_PASSTHROUGH` / `sni-dnat` east-west gateways is fully
  supported in sidecar mode; the topology is battle-tested.
- Locality-aware load balancing (`failoverPriority`) is a sidecar-level
  decision and works identically to single-cluster deployments.
- The demo workloads are small; the sidecar overhead is negligible
  relative to the 256 Mi memory limits.
- Ambient's cross-cluster story is newer; as of Istio 1.29 the
  recommended topology for multi-network multi-primary is still the
  sidecar east-west gateway. Re-evaluate for the next LTS.

## Consequences

- Every workload namespace must be labelled with `istio-injection: enabled`.
- Sidecar resource requests / limits must be planned into node sizing.
- Cilium (see ADR-0002) handles L3/L4 NetworkPolicy; Istio handles L7
  AuthorizationPolicy. Both are layered — see
  `clusters/base/my-app/network-policy.yaml`.

## Future work

- Re-evaluate ambient for a Tier-1 cluster (ADR-0001 option A) since
  that cluster only runs gateways, not user workloads, and waypoints
  may be a cleaner fit.
- When ambient is chosen for any portion, create ADR-0003a documenting
  the scope and the per-namespace migration.
