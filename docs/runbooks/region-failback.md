# Runbook — Region failback

Use this after a region has recovered and you want to safely return
traffic to it.

## Prerequisites

- The failed region's AKS cluster is fully healthy:
  - `kubectl get nodes` — all Ready
  - `kubectl get pods -A | grep -v Running` — empty
  - `kubectl get helmrelease -A --context=<recovered>` — all Ready
- The east-west gateway LB has an IP:
  `kubectl -n istio-system get svc istio-eastwestgateway --context=<recovered>`

## Staged re-entry

Do NOT simply delete the outage-time "quarantine" and let 100% of traffic
snap back. Stage it.

### Step 1 — Re-join the mesh (cross-cluster discovery)

If the remote secret was deleted during the incident, re-exchange:

```bash
RECOVERED=<aks-recovered>
OTHER=<aks-other>

istioctl create-remote-secret \
  --context=$RECOVERED \
  --name=$RECOVERED | \
  kubectl apply -f - --context=$OTHER
```

Verify the other clusters see the recovered one's endpoints:

```bash
POD=$(kubectl --context=$OTHER -n my-app get pod -l app=my-api -o jsonpath='{.items[0].metadata.name}')
istioctl --context=$OTHER proxy-config endpoints $POD -n my-app | grep my-api
# Expect to see both local + recovered cluster endpoints
```

### Step 2 — Re-enable the health-check controller

```bash
# If the controller was scaled to zero during the incident, scale back up:
kubectl --context=$RECOVERED -n health-check scale deploy health-check-controller --replicas=1

# Wait for probes to converge and the DNS service to reappear:
kubectl --context=$RECOVERED -n health-check get svc api-dns-record -w
```

### Step 3 — Re-register DNS (let ExternalDNS re-add the A record)

The controller recreates `api-dns-record` automatically when both tiers
(backend + gateway) have been healthy for `RECOVER_THRESHOLD` (default 2)
consecutive probes. Confirm:

```bash
dig +short @168.63.129.16 api.internal.contoso.com
# Should now include the recovered region's ILB IP
```

### Step 4 — Gradually shift load (if you have a Tier-1 gateway)

Until ADR-0001 is implemented, there is no programmable cross-region
weighting — DNS round-robin returns whatever is healthy. In the meantime:

- Use the `clusters/base/my-app/demo-traffic/cross-region-weighted.yaml`
  overlay to shift traffic 90/10 → 50/50 → 10/90 over several minutes.
- Watch per-region error rate and p95 latency before each shift.

### Step 5 — Post-incident

- Check `istiod` logs for persistent xDS push failures:
  `kubectl -n istio-system logs -l app=istiod --context=$RECOVERED`
- Scan the recovered region's outlier-ejection counters:
  `istioctl proxy-config clusters <pod> -n my-app --context=$OTHER -o json | jq '.[] | .outlierDetection'`
- File an incident retro; capture any ADR updates needed.

## Known gotchas

- If `cacerts` was rotated while the region was down, the recovered
  istiod may reject cross-cluster mTLS until the new CA propagates.
  See [ca-rotation.md](ca-rotation.md).
- Workload identity federated credentials do not auto-heal if the
  UAMI changed; verify `external-dns` pods are Ready before declaring
  DNS healthy.
