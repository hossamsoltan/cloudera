#!/usr/bin/env bash
set -euo pipefail

CSV=${1:-./hosts.csv}   # file with: fqdn,ip per line
mkdir -p /tmp/auto-tls/{keys,csrs}
[[ -f /tmp/auto-tls/keys/key.pwd ]] || echo 'KeyPassword#2026' > /tmp/auto-tls/keys/key.pwd
chmod 600 /tmp/auto-tls/keys/key.pwd

while IFS=, read -r HOSTNAME NODE_IP; do
  [[ -z "${HOSTNAME:-}" || -z "${NODE_IP:-}" ]] && continue
  SHORT="${HOSTNAME%%.*}"

  echo "Generating key+CSR for ${HOSTNAME} (${NODE_IP}) ..."
  openssl req -newkey rsa:4096 -sha256 -days 365 \
    -keyout "/tmp/auto-tls/keys/${HOSTNAME}-key.pem" \
    -out "/tmp/auto-tls/csrs/${HOSTNAME}.csr" \
    -passout file:/tmp/auto-tls/keys/key.pwd \
    -subj "/C=EG/ST=Cairo/L=Almazah/O=Red Hat inc/OU=rajhi/CN=${HOSTNAME}" \
    -extensions san -config <( \
      echo '[req]'; \
      echo 'distinguished_name=req'; \
      echo 'req_extensions=san'; \
      echo '[san]'; \
      echo "subjectAltName=DNS:${HOSTNAME}, DNS:${SHORT}, DNS:localhost, IP:${NODE_IP}, IP:127.0.0.1"; \
      echo 'extendedKeyUsage = serverAuth, clientAuth' )

  # quick sanity check
  openssl req -in "/tmp/auto-tls/csrs/${HOSTNAME}.csr" -noout -text |  egrep -A2 'Subject:|Subject Alternative Name|Extended Key Usage' || true
  sleep 1
done < "$CSV"

echo "All CSRs under /tmp/auto-tls/csrs and keys under /tmp/auto-tls/keys"
