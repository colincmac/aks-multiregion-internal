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
| `namespace-azure-alb-system.yaml` | `azure-alb-system` namespace for the ALB Controller. |
| `helmrepo-alb-controller.yaml` | Flux `HelmRepository` pointing at the ALB Controller OCI chart on MCR. |
| `helmrelease-alb-controller.yaml` | Flux `HelmRelease` that installs the ALB Controller with Workload Identity. |
| `kustomization.yaml` | Bundles the above. |

## How it is wired up

This overlay is included from the regional kustomizations in `clusters/east`
and `clusters/west`. The following one-time operator steps are required after
the infra layer (`infra/main.bicep`) has been deployed:

### Step 1 — Deploy the infra layer

```bash
az deployment sub create \
  --location eastus \
  --template-file infra/main.bicep \
  --parameters infra/main.example.bicepparam
```

Each cluster entry in `main.example.bicepparam` must include an
`albSubnetPrefix` (e.g. `10.1.19.0/24` for east, `10.2.19.0/24` for west).
`main.bicep` will:
- Add an AGC-delegated `snet-agc` subnet to each regional VNet.
- Create the AGC Traffic Controller and VNet association.
- Create the `mi-alb-controller-<cluster>` managed identity and wire its
  federated credential to the ALB Controller ServiceAccount.

### Step 2 — Render the per-region GitOps values

The regional overlay placeholders are now synchronized automatically by the
provisioning flow:

- `scripts/deploy.ps1` runs `scripts/sync-gitops-config.ps1` after a successful deployment.
- `azd provision` also triggers the same sync step via the post-provision hook in `azure.yaml`.

If you need to refresh the overlay values manually after a redeploy, run:

```powershell
./scripts/sync-gitops-config.ps1
```

This populates the AGC association IDs, the ALB Controller Workload Identity
client IDs, and the ExternalDNS Workload Identity client IDs in the regional
overlay patch files.

### Step 3 — Verify ALB Controller installation

Once Flux reconciles, the ALB Controller HelmRelease should be deployed in
`azure-alb-system`. Verify:

```bash
kubectl -n azure-alb-system get helmrelease azure-alb-controller
kubectl -n azure-alb-system get pods
```

### Step 4 — Verify AGC Gateway assignment

After the ALB Controller is running and the `ApplicationLoadBalancer` resource
references the correct association ID, the `Gateway` object should receive the
AGC private frontend IP in its `status.addresses`:

```bash
kubectl -n tier1-agc get gateway tier1-agc \
  -o jsonpath='{.status.addresses[*].value}{"\n"}'
```

Once the frontend IP is assigned, the health-check controller automatically:
- Switches the ExternalDNS A-record target from the Tier-2 ILB to the AGC
  private frontend IP.
- Starts probing the AGC frontend as a Tier-1 health check (three-tier GSLB).

## ExternalDNS / health-check integration

The health-check controller (in `clusters/base/health-check`) dynamically
discovers the AGC frontend IP from `gateway.status.addresses`. When the IP is
available it:

1. Creates `api-dns-record` as a headless Service with
   `external-dns.alpha.kubernetes.io/target: <agc-frontend-ip>`, so ExternalDNS
   publishes the AGC IP as the `api.internal.contoso.com` A record.
2. Probes `https://<agc-frontend-ip>/` (with `Host: api.internal.contoso.com`)
   as a Tier-1 health check. DNS is deregistered if this probe fails
   (independently of Tier-2 health).

If the `tier1-agc` Gateway is not yet deployed or has no address, the
controller falls back to the original ExternalName Service pointing at the
Tier-2 Istio ILB — ensuring backward-compatible rollout.

