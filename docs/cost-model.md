# Cost model (stub)

A starting reference for the monthly cost of this architecture. All
numbers are **rough, list-price estimates** in USD East-US; your actuals
depend on reserved-instance coverage, spot usage, and enterprise
agreement discounts.

## Per-region fixed costs

| Item | Qty | Approx. monthly |
|---|---|---|
| AKS control plane (Standard tier, private) | 1 | $73 |
| System node pool (Standard_D4s_v5, 2 nodes, 3 AZs) | 2 | ~$280 |
| User node pool baseline (Standard_D4s_v5, 3 nodes) | 3 | ~$420 |
| Internal Load Balancer (Standard) | 2 (tier-2 + east-west) | ~$38 |
| Azure Monitor Container Insights (log ingestion) | varies | $50 – $200 |
| VNet + subnet (fixed cost) | — | $0 |

**Per region fixed subtotal: ~$860–$1,020/month**

## Shared (global) fixed costs

| Item | Qty | Approx. monthly |
|---|---|---|
| Azure Private DNS zone | 1 | $0.50 |
| DNS queries (1M/mo) | — | $0.40 |
| VNet peering data transfer (cross-region, ~200 GB) | — | ~$7 |

**Shared subtotal: ~$10/month (dominated by cross-region egress)**

## Variable costs (drivers)

- **Cross-region east-west mesh traffic** — this is the single largest
  variable-cost line. Every cross-cluster RPC traverses VNet peering
  at ~$0.02/GB (Azure rates). A service doing 1,000 RPS with 10 KB
  payloads at 10% failover rate adds up to ~260 GB/month → ~$5. A
  chatty active-active workload at 10,000 RPS with 50 KB payloads at
  50% failover rate adds up to ~6.5 TB/month → ~$130.
- **Node-pool autoscaling** — at the HPA limits configured here (max 10
  per service) a burst can briefly triple node cost.
- **Log ingestion** — Istio access logs are verbose. Consider routing
  sidecar logs to a lower-retention table, or disabling in pre-prod.

## Cost optimisation levers

1. **Right-size sidecars** — the default sidecar requests 100m CPU /
   40 Mi memory. For low-traffic namespaces, lower this via
   `values.global.proxy.resources.requests` on the istiod HelmRelease.
2. **Reserved Instances / Savings Plans** for the system + user pools.
3. **Spot node pools** for stateless workloads; not for system.
4. **Prune Istio access logs** or sample them
   (`meshConfig.accessLogEncoding + telemetry`).
5. **Turn off cross-region failover during cost-exercises** — set
   `failoverPriority` temporarily to an empty list to keep traffic
   strictly local.
6. **Shared non-prod environment** — collapse dev + QA into one region.

## Items not yet priced

- Tier-1 cluster (ADR-0001) — would add one AKS control plane + one
  node pool per region used.
- Azure Front Door Premium (if chosen) — $165/mo base + egress.
- Azure Managed Prometheus + Grafana (Phase 5) — $50–$200 depending
  on metric volume.
- Azure Chaos Studio experiments — per-experiment billing, typically
  low unless run continuously.
- cert-manager + Key Vault (Phase 5) — Key Vault is ~$0.03 per 10K
  operations; negligible for CA operations.
