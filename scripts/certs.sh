for CTX in aks-eastus2 aks-centralus; do
  kubectl create secret generic cacerts -n istio-system \
    --from-file=ca-cert.pem \
    --from-file=ca-key.pem \
    --from-file=root-cert.pem \
    --from-file=cert-chain.pem \
    --context="$CTX"
done

# 2. Exchange remote secrets — each cluster needs a secret for every other cluster
CLUSTERS=(aks-eastus2 aks-centralus)
for SRC in "${CLUSTERS[@]}"; do
  for DST in "${CLUSTERS[@]}"; do
    if [ "$SRC" != "$DST" ]; then
      istioctl create-remote-secret \
        --context="$SRC" \
        --name="$SRC" | \
        kubectl apply -f - --context="$DST"
    fi
  done
done