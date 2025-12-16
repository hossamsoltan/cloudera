#!/bin/bash

KEYS_DIR="/tmp/auto-tls/keys"
CERTS_DIR="/tmp/auto-tls/certs_ad"
CA_CHAIN="/tmp/auto-tls/certs_ad/ca-chain.pem"
REMOTE_STAGE="/tmp/ssl-rotate-case3"

OK=0
FAIL=0

for host in $(cat hosts.txt); do
  echo "===== STAGING on $host ====="

  KEY_LOCAL="${KEYS_DIR}/${host}-key.pem"
  CERT_LOCAL="${CERTS_DIR}/${host}.cer"

  # create remote dir
  if ! ssh -o StrictHostKeyChecking=no "$host" "sudo mkdir -p $REMOTE_STAGE && sudo chown hossam:hossam $REMOTE_STAGE"; then
    echo "[ERROR] mkdir failed on $host"
    FAIL=$((FAIL+1))
    echo
    continue
  fi

  # copy files
  if ! scp -o StrictHostKeyChecking=no "$KEY_LOCAL" "$host:$REMOTE_STAGE/${host}-key.pem"; then
    echo "[ERROR] key copy failed on $host"
    FAIL=$((FAIL+1))
    echo
    continue
  fi

  if ! scp -o StrictHostKeyChecking=no "$CERT_LOCAL" "$host:$REMOTE_STAGE/${host}.cer"; then
    echo "[ERROR] cert copy failed on $host"
    FAIL=$((FAIL+1))
    echo
    continue
  fi

  if ! scp -o StrictHostKeyChecking=no "$CA_CHAIN" "$host:$REMOTE_STAGE/ca-chain.pem"; then
    echo "[ERROR] ca-chain copy failed on $host"
    FAIL=$((FAIL+1))
    echo
    continue
  fi

  # verify
  if ssh -o StrictHostKeyChecking=no "$host" "ls -lh $REMOTE_STAGE/${host}-key.pem $REMOTE_STAGE/${host}.cer $REMOTE_STAGE/ca-chain.pem"; then
    echo "[OK] staged on $host"
    OK=$((OK+1))
  else
    echo "[ERROR] verify failed on $host"
    FAIL=$((FAIL+1))
  fi

  echo
done

echo "========== SUMMARY =========="
echo "OK   : $OK"
echo "FAIL : $FAIL"
