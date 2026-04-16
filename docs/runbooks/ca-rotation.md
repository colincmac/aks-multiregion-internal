# Runbook — Root / intermediate CA rotation

The cross-cluster mesh trusts a shared root CA whose intermediate is
installed into each cluster as the `cacerts` secret in `istio-system`.
Rotation must preserve cross-cluster mTLS throughout the transition.

## When to rotate

- On a fixed schedule (recommended: annual for root, quarterly for
  intermediates).
- Immediately on suspected key compromise.
- Before an intermediate's `notAfter` is within 30 days.

## Safe rotation sequence

### Option A — Keep root, rotate intermediates (preferred)

This is zero-downtime provided all clusters trust the same root.

1. Generate a new per-cluster intermediate signed by the existing root:
   ```bash
   openssl req -new -key ca-key-<cluster>.pem -out intermediate-<cluster>.csr -config <csr.cnf>
   openssl x509 -req -in intermediate-<cluster>.csr -CA root-cert.pem -CAkey root-key.pem \
     -CAcreateserial -out ca-cert-<cluster>.pem -days 365 -extensions v3_ca -extfile <v3.cnf>
   cat ca-cert-<cluster>.pem root-cert.pem > cert-chain-<cluster>.pem
   ```
2. For each cluster, update the `cacerts` secret. Istiod picks up the
   new cert-chain and root on the next reconcile (the default file-watch
   interval is small — typically within ~30s):
   ```bash
   kubectl --context=$CTX -n istio-system create secret generic cacerts \
     --from-file=ca-cert.pem=ca-cert-<cluster>.pem \
     --from-file=ca-key.pem=ca-key-<cluster>.pem \
     --from-file=root-cert.pem=root-cert.pem \
     --from-file=cert-chain.pem=cert-chain-<cluster>.pem \
     --dry-run=client -o yaml | kubectl apply -f - --context=$CTX
   ```
3. Istiod regenerates workload certs on its normal cadence. Force-rotate
   by restarting istiod if urgency is required:
   `kubectl -n istio-system rollout restart deploy/istiod --context=$CTX`.
4. Verify chain:
   `istioctl proxy-config secret <pod> -n my-app --context=$CTX -o json | jq '.dynamicActiveSecrets[] | .secret.validationContext'`

### Option B — Replace the root

Use a transition root that includes BOTH the old and new roots in its
bundle so clusters trust both during the overlap window.

1. Build a combined root bundle:
   `cat old-root.pem new-root.pem > root-cert.pem`
2. Apply to every cluster's `cacerts` (Option A steps 2–3).
3. Wait for all workload certs to rotate and all sidecars to reload the
   new root. Istio's default workload cert lifetime is 24h, so a full
   passive rotation can take up to ~24h. Faster if you force a restart
   of every istio-proxy (`kubectl rollout restart deploy -A`).
4. Reissue intermediates signed by the NEW root.
5. Remove the OLD root from `root-cert.pem` and reapply.

### Option C — In the future: cert-manager + Azure Key Vault issuer

Recommended for automation (separate PR, pending ADR):

- Root CA lives in Azure Key Vault (HSM-backed, never leaves the vault).
- cert-manager with the `azurekeyvault-issuer` produces a per-cluster
  intermediate `CertificateRequest`; cert-manager renews and updates
  the `cacerts` secret automatically.
- Federated Workload Identity gives cert-manager access to Key Vault.

## Validation checklist

- [ ] Each cluster's `cacerts` secret has the new chain.
- [ ] `istioctl proxy-status --context=$CTX` reports all sidecars
      SYNCED.
- [ ] Cross-cluster curl through east-west gateway succeeds from a test
      pod in the opposite cluster.
- [ ] No surge in `5xx` or `0x000` disconnects on east-west gateway
      metrics.

## Gotchas

- If the `cacerts` secret was applied AFTER istiod first started with a
  self-signed CA, every existing workload has a cert signed by the
  self-signed CA that will be rejected by other clusters. Roll all
  workloads (delete all pods in meshed namespaces) after the first
  `cacerts` install to force re-issuance.
- Never drop the `root-cert.pem` in Option B before all clients have
  rotated to the new root. Monitor the
  `istio_requests_total{response_code="0"}` metric during transition.
