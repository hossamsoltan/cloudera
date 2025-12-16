KEYS_DIR="/tmp/auto-tls/keys"
CERTS_DIR="/tmp/auto-tls/certs_ad"
CA_CHAIN="/tmp/auto-tls/certs_ad/ca-chain.pem"

echo "Checking CA chain:"
test -f "$CA_CHAIN" && echo "OK: ca-chain.pem exists" || echo "ERROR: missing ca-chain.pem"

echo
echo "Checking per-host key/cert files..."
missing=0
while read -r h; do
  k="${KEYS_DIR}/${h}-key.pem"
  c="${CERTS_DIR}/${h}.cer"

  if [ ! -f "$k" ]; then
    echo "MISSING KEY: $k"
    missing=1
  fi

  if [ ! -f "$c" ]; then
    echo "MISSING CERT: $c"
    missing=1
  fi
done < hosts.txt

if [ "$missing" -eq 0 ]; then
  echo
  echo "OK: all host key/cert files exist."
else
  echo
  echo "ERROR: missing files — stop here."
fi

