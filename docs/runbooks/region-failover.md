# Runbook — Region failover

Use this when a region is degraded or fully unreachable and you need to
confirm (or force) that traffic has moved to the surviving region(s).

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
