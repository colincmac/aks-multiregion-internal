# Runbook — DNS zone recovery

The Azure Private DNS zone `internal.contoso.com` is the GSLB source of
truth. If it is damaged, deleted, or its records are inconsistent across
clusters, use this runbook.

## Common failure modes

1. **Stale A record** — a failed region's ILB IP is still in the zone
   because the health-check controller failed to deregister.
2. **Stale TXT owner record** — ExternalDNS owns records via TXT
   records; if a TXT lingers from a deleted cluster, the live ExternalDNS
   instances will refuse to modify those records.
3. **Zone-level mis-link** — a newly peered VNet is not linked to the
   private zone, so pods in that cluster can't resolve internal names.
4. **Zone deleted or soft-deleted** — rare, but the zone is gone.

## Triage

```bash
# What does the zone actually contain?
az network private-dns record-set list \
  --resource-group rg-<env>-global \
  --zone-name internal.contoso.com \
  -o table

# Are all cluster VNets linked?
az network private-dns link vnet list \
  --resource-group rg-<env>-global \
  --zone-name internal.contoso.com \
  -o table

# What does each cluster resolve?
for CTX in aks-eastus2 aks-centralus; do
  echo "--- $CTX ---"
  kubectl --context=$CTX -n external-dns logs -l app=external-dns --tail=30 | grep -Ei 'api|err'
done
```

## Recovery actions

### 1. Stale A-record IP

```bash
# Identify the IP and remove it:
az network private-dns record-set a remove-record \
  --resource-group rg-<env>-global \
  --zone-name internal.contoso.com \
  --record-set-name api \
  --ipv4-address <stale-ip>
```

Then ensure the owning cluster's health-check controller is running so
the record won't be re-added if the region is actually unhealthy.

### 2. Stale TXT owner record

```bash
# Find owner TXTs:
az network private-dns record-set txt list \
  --resource-group rg-<env>-global \
  --zone-name internal.contoso.com \
  --query "[?starts_with(name, '_externaldns-')]" -o table

# Remove a specific owner (e.g. a decommissioned cluster):
az network private-dns record-set txt delete \
  --resource-group rg-<env>-global \
  --zone-name internal.contoso.com \
  --name _externaldns-api \
  --yes
```

After removing the stale TXT, restart ExternalDNS on the surviving
clusters so each one re-asserts ownership of records it manages.

### 3. Missing VNet link

```bash
# Link a newly peered VNet:
az network private-dns link vnet create \
  --resource-group rg-<env>-global \
  --zone-name internal.contoso.com \
  --name link-<cluster> \
  --virtual-network <vnet-resource-id> \
  --registration-enabled false
```

Prefer redeploying `infra/main.bicep` with the new cluster in the
`clusters` array so Bicep manages the link idempotently.

### 4. Zone deleted / recreated

1. Redeploy Bicep: the `privateDnsZone` module recreates the zone and
   re-links all VNets.
2. Delete and recreate `api-dns-record` on every cluster to force
   ExternalDNS to re-publish:
   ```bash
   for CTX in aks-eastus2 aks-centralus; do
     kubectl --context=$CTX -n health-check delete service api-dns-record --ignore-not-found=true
     kubectl --context=$CTX -n health-check rollout restart deploy health-check-controller
   done
   ```
3. Verify the expected A records return within ~1 minute.

## Validation

```bash
for CTX in aks-eastus2 aks-centralus; do
  kubectl --context=$CTX run dig-test --image=busybox:stable --restart=Never --rm -it -- \
    sh -c 'nslookup api.internal.contoso.com || true'
done
```

## Gotchas

- ExternalDNS with `--policy=sync` will delete records it does NOT own;
  verify `--txt-owner-id` is set to a unique per-cluster value before
  enabling sync. The east/west overlays already do this via
  `externaldns-patch.yaml`.
- Azure Private DNS has per-zone RRset limits; long-running churn can
  hit throttling. Keep `--interval` at 10s or higher.
