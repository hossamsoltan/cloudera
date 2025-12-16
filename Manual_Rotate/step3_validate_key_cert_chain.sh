#!/bin/bash
set -e

HOSTS_FILE="hosts.txt"
KEYS_DIR="/tmp/auto-tls/keys"
CERTS_DIR="/tmp/auto-tls/certs_ad"
CA_CHAIN="/tmp/auto-tls/certs_ad/ca-chain.pem"

echo "Using CA chain: $CA_CHAIN"
echo

# Check CA chain itself
openssl x509 -in "$CA_CHAIN" -noout -subject -issuer >/dev/null

while read -r host; do
  echo "===== VALIDATING $host ====="

  KEY="${KEYS_DIR}/${host}-key.pem"
  CERT_RAW="${CERTS_DIR}/${host}.cer"
  CERT_PEM="/tmp/${host}.pem"

  # Convert cert to PEM if needed
  if openssl x509 -in "$CERT_RAW" -noout >/dev/null 2>&1; then
    cp -f "$CERT_RAW" "$CERT_PEM"
  else
    openssl x509 -inform der -in "$CERT_RAW" -out "$CERT_PEM"
  fi

  # 1) Key ↔ cert modulus match
  KM="$(openssl rsa -in "$KEY" -noout -modulus | openssl md5)"
  CM="$(openssl x509 -in "$CERT_PEM" -noout -modulus | openssl md5)"

  if [ "$KM" != "$CM" ]; then
    echo "❌ ERROR: key does NOT match cert for $host"
    exit 1
  fi
  echo "✔ Key matches certificate"

  # 2) Verify cert validity dates
  openssl x509 -in "$CERT_PEM" -noout -dates

  # 3) Verify cert chains to CA
  if openssl verify -CAfile "$CA_CHAIN" "$CERT_PEM" >/dev/null 2>&1; then
    echo "✔ Certificate chains correctly to CA"
  else
    echo "❌ ERROR: certificate does NOT chain correctly to CA"
    exit 1
  fi

  rm -f "$CERT_PEM"
  echo
done < "$HOSTS_FILE"

echo "ALL hosts passed key/cert/CA validation."
