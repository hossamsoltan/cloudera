#!/bin/bash
set -e

HOSTS_FILE="hosts.txt"
REMOTE_DIR="/var/lib/cloudera-scm-agent/agent-cert"
BACKUP_BASE="/var/backups/cloudera-agent-cert"
TS="$(date +%F_%H%M%S)"

echo "Backup timestamp: $TS"
echo

while read -r host; do
  echo "===== BACKUP on $host ====="
  ssh -o StrictHostKeyChecking=no "$host" <<EOSSH
    set -e
    sudo test -d "$REMOTE_DIR"
    sudo mkdir -p "$BACKUP_BASE"
    sudo tar -czf "$BACKUP_BASE/agent-cert_$TS.tgz" -C "$REMOTE_DIR" .
    sudo ls -lh "$BACKUP_BASE/agent-cert_$TS.tgz"
EOSSH
  echo
done < "$HOSTS_FILE"

echo "All backups completed."
echo "Timestamp used: $TS"
