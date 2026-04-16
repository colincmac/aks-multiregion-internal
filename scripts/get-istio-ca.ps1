$secretName = kubectl get clusterissuers bar -o jsonpath='{.spec.ca.secretName}'
$encodedCert = kubectl get secret $secretName -n cert-manager -o jsonpath='{.data.ca\.crt}'
$decodedCert = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encodedCert))
$ISTIOCA = ($decodedCert -split "`n" | ForEach-Object { "        $_" }) -join "`n"


$ISTIOCA
