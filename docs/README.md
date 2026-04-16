# Documentation

Architecture and operations documentation for the multi-region AKS service mesh.

## Architecture Decision Records (`adr/`)

Each ADR records a significant choice, the alternatives considered, and the consequences. Items marked **Proposed** are decisions that remain open — see the issue tracker before implementing the dependent work.

| # | Title | Status |
|---|-------|--------|
| [0001](adr/0001-tier1-gateway-choice.md) | Tier-1 gateway choice | **Proposed** (decision pending) |
| [0002](adr/0002-cni-choice.md) | CNI choice: Azure Overlay + Cilium, no istio-cni | Accepted |
| [0003](adr/0003-sidecar-vs-ambient.md) | Sidecar mode vs. Istio ambient | Accepted (sidecar); ambient tracked as future work |
| [0004](adr/0004-gslb-ttl-and-probe-cadence.md) | GSLB DNS TTL and health-probe cadence | Accepted |
| [0005](adr/0005-default-deny-authz.md) | Mesh-wide default-deny AuthorizationPolicy | Accepted |

## Runbooks (`runbooks/`)

Operator procedures for common day-2 tasks and failures.

| Runbook | When to use |
|---------|-------------|
| [region-failover.md](runbooks/region-failover.md) | A region is degraded or down; verify traffic has moved |
| [region-failback.md](runbooks/region-failback.md) | Region has recovered; safely return traffic |
| [ca-rotation.md](runbooks/ca-rotation.md) | Rotate the shared root / per-cluster intermediate CA |
| [istiod-canary-upgrade.md](runbooks/istiod-canary-upgrade.md) | Upgrade the Istio control plane using revisions |
| [dns-zone-recovery.md](runbooks/dns-zone-recovery.md) | Azure Private DNS zone is damaged / records are stale |

## Other

- [`threat-model.md`](threat-model.md) — STRIDE threat model for the platform
- [`cost-model.md`](cost-model.md) — Monthly cost estimation and cost-optimisation levers
