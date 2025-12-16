#!/bin/bash

OK=0
FAIL=0

for host in $(cat hosts.txt); do
  echo "===== RESTART AGENT on $host ====="

  if ssh -o StrictHostKeyChecking=no "$host" \
     "sudo systemctl restart cloudera-scm-agent && sudo systemctl is-active cloudera-scm-agent"; then
    echo "[OK] agent running on $host"
    OK=$((OK+1))
  else
    echo "[FAIL] agent restart failed on $host"
    FAIL=$((FAIL+1))
  fi

  echo
done

echo "========== SUMMARY =========="
echo "OK   : $OK"
echo "FAIL : $FAIL"
