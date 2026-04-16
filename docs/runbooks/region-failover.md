# Runbook — Region failover

Use this when a region is degraded or fully unreachable and you need to
confirm (or force) that traffic has moved to the surviving region(s).

> **Tier-1 note (ADR-0001, Option E):** once the Tier-1 AGC overlay
> (`clusters/base/tier1-agc`) is wired in per region, the DNS A record
> for `api.internal.contoso.com` points at the regional AGC private
> frontend IP (not the Tier-2 ILB). Pre-flight and failover steps then
> gain a Tier-1 layer — see "Tier-1 (AGC) checks" at the bottom of this
> runbook. Until that wiring is done, the steps below continue to apply
> unchanged.

## Symptoms

- Clients report elevated latency or errors.
- `api.internal.contoso.com` is still returning the IP of a region that
  is itself unhealthy (stale DNS record).
- Azure Service Health shows an incident in one region.

## Pre-flight checks

```bash
# Which regions currently contribute A records?
dig +short @168.63.129.16 api.internal.contoso.com

# Per-cluster health-check controller status
for CTX in aks-eastus2 aks-centralus; do
  echo "--- $CTX ---"
  kubectl --context=$CTX -n health-check logs -l app=health-check-controller --tail=20
done

# Are the ingress gateway pods up?
for CTX in aks-eastus2 aks-centralus; do
  kubectl --context=$CTX -n my-app get pods -l gateway.networking.k8s.io/gateway-name=internal-api-gateway
done

# Cross-cluster endpoints Istio can see
for CTX in aks-eastus2 aks-centralus; do
  POD=$(kubectl --context=$CTX -n my-app get pod -l app=my-api -o jsonpath='{.items[0].metadata.name}')
  istioctl --context=$CTX proxy-config endpoints $POD -n my-app | grep my-api
done
```

## Automatic failover path (preferred)

1. The in-region health-check controller detects the failure (backend
   probe, gateway probe, or both) and deletes `api-dns-record` in the
   `health-check` namespace.
2. ExternalDNS picks up the deletion and removes that cluster's A-record
   contribution from Azure Private DNS.
3. DNS clients with expired TTLs resolve only the surviving regions.
4. In-mesh traffic for the affected service is already failing over via
   Istio locality LB (outlier detection + `failoverPriority`).

Total worst-case: ~55s (see [ADR-0004](../adr/0004-gslb-ttl-and-probe-cadence.md)).

## Manual failover (when the controller is itself down)

```bash
# Force-delete the DNS record from the failing region:
kubectl --context=<failing-cluster> -n health-check delete service api-dns-record

# Or, from ANY cluster, delete the TXT owner record directly in Azure:
az network private-dns record-set txt delete \
  --resource-group rg-<env>-global \
  --zone-name internal.contoso.com \
  --name _externaldns-api \
  --yes
az network private-dns record-set a show \
  --resource-group rg-<env>-global \
  --zone-name internal.contoso.com \
  --name api
# Remove the stale IP via `record-set a remove-record`
```

## Verify

```bash
# DNS now points only at healthy region(s)
dig +short @168.63.129.16 api.internal.contoso.com

# Client success rate recovers (adjust as needed for your probe):
watch -n2 'for i in 1 2 3 4 5; do curl -s -o /dev/null -w "%{http_code}\n" \
  --resolve api.internal.contoso.com:443:<healthy-ilb-ip> \
  https://api.internal.contoso.com/; done'

# Cross-cluster mTLS is healthy
istioctl --context=<healthy-cluster> proxy-config clusters <pod> -n my-app | grep my-api
```

## Rollback / re-entry

Follow [region-failback.md](region-failback.md) once the region is healthy.

## Known gotchas

- Long-lived clients cache DNS — if a pinned client is still hitting the
  failed region, reissue connections client-side or restart the
  offending client pods.
- If the mesh-wide default-deny AuthZ policy (ADR-0005) was reverted
  during incident response, verify explicit allow policies are still in
  place for `my-api` ← ingress and `my-api-backend` ← `my-api`.

## Tier-1 (AGC) checks — applicable once ADR-0001 Option E is wired in

```bash
# Which AGC private frontend IP is DNS currently resolving to?
dig +short @168.63.129.16 api.internal.contoso.com

# AGC health — from Azure (each region):
az network alb show \
  -g rg-istio-mesh-eastus2 \
  -n agc-istio-mesh-eastus2 \
  --query 'properties.provisioningState'

# Gateway API state in-cluster (each region):
for CTX in aks-eastus2 aks-centralus; do
  echo "--- $CTX ---"
  kubectl --context=$CTX -n tier1-agc get gateway tier1-agc \
    -o jsonpath='{.status.addresses[*].value}{"\n"}'
  kubectl --context=$CTX -n tier1-agc get httproute tier1-to-tier2 \
    -o jsonpath='{.status.parents[*].conditions[?(@.type=="Accepted")].status}{"\n"}'
done
```

If Tier-1 AGC is healthy but Tier-2 is not, the Tier-1 probe in the
health-check controller (ADR-0004 follow-up) still removes the region's
AGC IP from the DNS record — no manual intervention is required. If
AGC itself is the failure mode, force-delete `api-dns-record` in the
affected region's `health-check` namespace as described above.

### Future: Azure Private Traffic Manager

When Azure Private Traffic Manager GAs, the ExternalDNS A record is
replaced by a Private Traffic Manager profile whose endpoints are the
same per-region AGC private IPs. Failover then happens at the Private
Traffic Manager profile (endpoint health + DNS response weighting) and
this runbook's "force-delete the ExternalDNS Service" step is replaced
by "disable the endpoint in the Private Traffic Manager profile". The
in-cluster Tier-1 and Tier-2 steps are unchanged.
