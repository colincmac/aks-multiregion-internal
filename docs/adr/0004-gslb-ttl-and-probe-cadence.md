# ADR-0004 — GSLB DNS TTL and health-probe cadence

- **Status:** Accepted
- **Date:** initial deployment

> **Related:** [ADR-0001](./0001-tier1-gateway-choice.md) adopts a
> Tier-1 AGC in front of the Tier-2 Istio ingress. Once that is wired
> in, the A record managed here points at the regional AGC private
> frontend IP and the health-check controller also runs a Tier-1
> probe. When Azure Private Traffic Manager GAs, the DNS layer defined
> in this ADR is replaced by a Private Traffic Manager profile whose
> endpoints are the same AGC private IPs; the TTL/probe parameters
> below move into the Private Traffic Manager profile configuration.

## Context

The per-cluster health-check controller toggles an ExternalDNS-annotated
`Service` in Azure Private DNS to add or remove a region's ILB IP from
the `api.internal.contoso.com` A record. The failover time budget is
determined by four parameters:

1. `PROBE_INTERVAL` — how often the controller probes (5s).
2. `FAIL_THRESHOLD` — consecutive failures before deregistering (3).
3. ExternalDNS `--interval` — how often ExternalDNS reconciles (10s).
4. DNS TTL — how long clients cache the answer (30s).

Worst case: `(5s × 3) + 10s + 30s ≈ 55s`.

## Decision

Keep the defaults:

| Parameter | Value | Rationale |
|---|---|---|
| DNS TTL | 30s | Balance of failover speed vs. DNS amplification load. |
| Probe interval | 5s | Fast enough to detect failures within a TCP retransmit cycle. |
| Fail threshold | 3 | Tolerates a single lost probe without flapping. |
| Recover threshold | 2 | Avoids re-registering a flaky region. |
| Probe timeout | 3s | Shorter than interval so probes complete before the next one. |
| ExternalDNS interval | 10s | Azure Private DNS rate limits; 10s is safely below throttling. |

## Consequences

- Client-observed failover is capped at ~55s. Long-lived connections
  survive longer because TCP connections don't re-resolve DNS until they
  are re-established.
- Reducing TTL below ~5s is rarely worthwhile: Azure Private DNS has a
  minimum TTL of 1s but client resolvers (including Azure DNS recursive
  resolvers used by Private DNS resolution) may not honor sub-second TTLs.
- Long-lived / DNS-cached clients are the real bottleneck. The plan for
  closing this gap is the Tier-1 gateway (ADR-0001), which lets clients
  keep a single endpoint while the Tier-1 does per-request regional
  routing.

## When to revisit

- After adopting a Tier-1 gateway: DNS GSLB demotes to "regional entry
  selection" and TTL can safely rise to several minutes because the
  Tier-1 handles per-request routing.
- For truly latency-sensitive workloads: consider client-SDK region
  awareness (Cosmos DB SDK, Service Bus SDK already do this) rather
  than tightening DNS further.

## Alternatives considered

- **TTL=1s**: rejected — no measurable benefit over 30s for realistic
  clients, higher QPS on Azure DNS.
- **Probe interval=1s**: rejected — increases controller noise and
  ExternalDNS churn without moving the bottleneck (TTL dominates).
