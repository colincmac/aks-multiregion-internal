# Runbook — Istiod canary upgrade

The Istio project recommends upgrading the control plane using **revisions**
so the new `istiod` runs alongside the old one and workloads migrate
namespace-by-namespace.

## Prerequisites

- Pick the target minor version (e.g. Istio 1.30).
- The new version's Helm charts exist in the `istio` HelmRepository. Today
  the HelmRelease pins `1.29.*`; upgrading means adding a NEW HelmRelease
  for the target revision rather than editing the existing one in-place.

## Revision layout in this repo

Each cluster overlay (`clusters/east`, `clusters/west`) today has a single
`helmrelease-istiod.yaml`. To canary a new revision without touching the
running one:

1. Add a parallel file `helmrelease-istiod-1-30.yaml` whose chart version
   is `1.30.*` and whose HelmRelease name is `istiod-1-30`. Set:
   ```yaml
   values:
     revision: "1-30"
     global:
       meshID: shared-mesh
       multiCluster:
         clusterName: cluster-east
       network: network-east
   ```
2. Reference the new file from `clusters/east/kustomization.yaml`. Flux
   will install the second istiod alongside the first.
3. Add a second east-west gateway if the minor version introduces
   gateway-level changes; otherwise the existing one continues to serve
   both revisions.

## Namespace-by-namespace migration

1. For each test namespace, switch the `istio-injection` label to the
   revision label:
   ```bash
   kubectl label namespace my-app istio-injection- istio.io/rev=1-30 --overwrite
   kubectl rollout restart deploy -n my-app
   ```
2. Verify the pods are now using the new revision:
   ```bash
   istioctl proxy-status | grep my-app
   # Look for istiod-1-30 in the control plane column.
   ```
3. Watch metrics, traces, and error rates. Roll back by flipping the
   label:
   ```bash
   kubectl label namespace my-app istio.io/rev- istio-injection=enabled --overwrite
   kubectl rollout restart deploy -n my-app
   ```

## Remove the old revision

Only after every namespace has migrated AND you've kept the new revision
running for long enough to trust (recommend 1–2 weeks):

1. Delete the old `helmrelease-istiod.yaml`.
2. Delete the old east-west gateway HelmRelease if you canaried it.
3. Commit + push. Flux prunes the old `istiod` deployment.

## Verification checklist

- [ ] `istioctl version` shows both revisions on the control plane and
      converges to one after cleanup.
- [ ] `istioctl proxy-status` reports every sidecar SYNCED.
- [ ] Cross-cluster east-west traffic works:
      `istioctl proxy-config endpoints <pod> -n my-app | grep my-api`
- [ ] Mesh-wide `istio_requests_total{response_code!~"2.."}` has not
      spiked during the transition.

## Gotchas

- `PeerAuthentication`, `AuthorizationPolicy`, and Gateway-API
  resources are revision-agnostic — they keep working across the
  upgrade.
- `EnvoyFilter`s can be revision-sensitive; audit them before
  canarying.
- Remote cluster secrets refer to cluster names, not revisions — no
  change needed.
- A HelmRelease upgrade that bumps the **same** chart version in-place
  is NOT a revision upgrade; it's an unsafe rolling restart. Always
  use the parallel-revision approach for minor-version bumps.
