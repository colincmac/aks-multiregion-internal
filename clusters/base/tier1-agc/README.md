# Tier-1 Gateway overlay — Application Gateway for Containers (AGC)

This overlay implements the L7 Tier-1 gateway decided in
[`docs/adr/0001-tier1-gateway-choice.md`](../../../docs/adr/0001-tier1-gateway-choice.md)
(Option E: AGC per region + future Azure Private Traffic Manager).

## What it contains

| File | Purpose |
|---|---|
| `applicationloadbalancer.yaml` | Binds the cluster to the AGC Azure resource provisioned by `infra/modules/tier1-agc.bicep` (one AGC per region). |
| `gateway.yaml` | Gateway API `Gateway` on the `azure-alb-external` class, using the AGC private frontend as the listener address. |
| `httproute.yaml` | `HTTPRoute` forwarding `api.internal.contoso.com` to the regional Istio Tier-2 ingress gateway service. |
| `backendtlspolicy.yaml` | Backend mTLS policy so AGC originates mTLS to the Tier-2 Istio ingress gateway. |
| `namespace.yaml` | `tier1-agc` namespace. |
| `kustomization.yaml` | Bundles the above. |

## How it is wired up (follow-up, not in this PR)

1. Install the ALB Controller Helm chart in each regional AKS cluster
   and grant its workload identity federated credentials to the user-
   assigned managed identity referenced by `tier1-agc.bicep`.
2. Fill in the per-region placeholders in `applicationloadbalancer.yaml`
   (AGC resource ID + frontend name from the Bicep module outputs).
3. Add `../base/tier1-agc` to the regional overlays in `clusters/east`
   and `clusters/west`.
4. Repoint ExternalDNS to the AGC private frontend IP (see ADR-0004
   follow-ups).

Until step 3, this overlay is **not** included from any regional
kustomization, so it is safe to land alongside the ADR.
