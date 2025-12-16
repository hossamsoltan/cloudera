#!/bin/bash

AGENT_CERT_DIR="/var/lib/cloudera-scm-agent/agent-cert"
STAGE_DIR="/tmp/ssl-rotate-case3"

OK=0
FAIL=0

for host in $(cat hosts.txt); do
  echo "===== INSTALL on $host ====="

  ssh -o StrictHostKeyChecking=no "$host" <<EOSSH
set -e

AGENT_CERT_DIR="/var/lib/cloudera-scm-agent/agent-cert"
STAGE_DIR="/tmp/ssl-rotate-case3"

# Read EXISTING password on this host
KEY_PASS=\$(sudo cat "\$AGENT_CERT_DIR/cm-auto-host_key.pw")

# Sanity checks
sudo test -f "\$STAGE_DIR/${host}-key.pem"
sudo test -f "\$STAGE_DIR/${host}.cer"
sudo test -f "\$STAGE_DIR/ca-chain.pem"
sudo test -f "\$AGENT_CERT_DIR/cm-auto-host_key.pw"

# Build cert chain
cat "\$STAGE_DIR/${host}.cer" "\$STAGE_DIR/ca-chain.pem" | \
  sudo tee "\$AGENT_CERT_DIR/cm-auto-host_cert_chain.pem" >/dev/null

# Install host key
sudo cp -f "\$STAGE_DIR/${host}-key.pem" \
           "\$AGENT_CERT_DIR/cm-auto-host_key.pem"

# Rebuild host keystore
sudo rm -f "\$AGENT_CERT_DIR/cm-auto-host_keystore.jks"

sudo openssl pkcs12 -export \
  -in "\$AGENT_CERT_DIR/cm-auto-host_cert_chain.pem" \
  -inkey "\$AGENT_CERT_DIR/cm-auto-host_key.pem" \
  -name cloudera-host \
  -out /tmp/host.p12 \
  -password pass:\$KEY_PASS

sudo keytool -importkeystore \
  -destkeystore "\$AGENT_CERT_DIR/cm-auto-host_keystore.jks" \
  -deststoretype JKS \
  -deststorepass "\$KEY_PASS" \
  -srckeystore /tmp/host.p12 \
  -srcstoretype PKCS12 \
  -srcstorepass "\$KEY_PASS" >/dev/null

# Permissions
sudo chown cloudera-scm:cloudera-scm \
  "\$AGENT_CERT_DIR/cm-auto-host_key.pem" \
  "\$AGENT_CERT_DIR/cm-auto-host_cert_chain.pem" \
  "\$AGENT_CERT_DIR/cm-auto-host_keystore.jks"

sudo chmod 600 "\$AGENT_CERT_DIR/cm-auto-host_key.pem"
sudo chmod 600 "\$AGENT_CERT_DIR/cm-auto-host_keystore.jks"
sudo chmod 644 "\$AGENT_CERT_DIR/cm-auto-host_cert_chain.pem"

# Show cert dates
echo "[INFO] Certificate validity:"
openssl x509 -in "\$AGENT_CERT_DIR/cm-auto-host_cert_chain.pem" -noout -dates

sudo rm -f /tmp/host.p12
EOSSH

  if [ $? -eq 0 ]; then
    echo "[OK] installed on $host"
    OK=$((OK+1))
  else
    echo "[FAIL] install failed on $host"
    FAIL=$((FAIL+1))
  fi

  echo
done

echo "========== SUMMARY =========="
echo "OK   : $OK"
echo "FAIL : $FAIL"
