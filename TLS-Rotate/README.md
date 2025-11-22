# Auto-TLS Certificate Rotation Guide

This guide provides steps to rotate Auto-TLS certificates using a custom CA for your Cloudera Manager cluster.

## Prerequisites

- Cloudera Manager admin credentials
- Root SSH access to all cluster hosts
- New certificates and keys generated for all hosts
- Certificates and keys stored on the Cloudera Manager server at specified paths
- `jq` command-line JSON processor installed

## Host Information

**Cloudera Manager Server:** `utility1.my.bigdata.local`

**Cluster Hosts:**
- Utility nodes: utility1, utility2
- Worker nodes: worker1, worker2, worker3  
- Master nodes: master1, master2, master3
- Gateway nodes: gateway1, gateway2
- KMS nodes: kms1, kms2
- KTS nodes: kts1, kts2

## Step 1: Upload Custom Certificates to Cloudera Manager

Run this command to upload all host certificates and keys:

```bash
curl -k -u admin:admin -X POST \
  --header 'Content-Type: application/json' \
  --header 'Accept: application/json' \
  -d '{
    "location": "/opt/cloudera/AutoTLS",
    "interpretAsFilenames": true,
    "hostCerts": [ 
        { "hostname": "utility1.my.bigdata.local", "certificate": "/tmp/auto-tls/certs/utility1.my.bigdata.local.cer", "key": "/tmp/auto-tls/keys/utility1.my.bigdata.local-key.pem" },
        { "hostname": "utility2.my.bigdata.local", "certificate": "/tmp/auto-tls/certs/utility2.my.bigdata.local.cer", "key": "/tmp/auto-tls/keys/utility2.my.bigdata.local-key.pem" },
        { "hostname": "worker1.my.bigdata.local",  "certificate": "/tmp/auto-tls/certs/worker1.my.bigdata.local.cer",  "key": "/tmp/auto-tls/keys/worker1.my.bigdata.local-key.pem" },
        { "hostname": "worker2.my.bigdata.local",  "certificate": "/tmp/auto-tls/certs/worker2.my.bigdata.local.cer",  "key": "/tmp/auto-tls/keys/worker2.my.bigdata.local-key.pem" },
        { "hostname": "worker3.my.bigdata.local",  "certificate": "/tmp/auto-tls/certs/worker3.my.bigdata.local.cer",  "key": "/tmp/auto-tls/keys/worker3.my.bigdata.local-key.pem" },
        { "hostname": "master1.my.bigdata.local",  "certificate": "/tmp/auto-tls/certs/master1.my.bigdata.local.cer",  "key": "/tmp/auto-tls/keys/master1.my.bigdata.local-key.pem" },
        { "hostname": "master2.my.bigdata.local",  "certificate": "/tmp/auto-tls/certs/master2.my.bigdata.local.cer",  "key": "/tmp/auto-tls/keys/master2.my.bigdata.local-key.pem" },
        { "hostname": "master3.my.bigdata.local",  "certificate": "/tmp/auto-tls/certs/master3.my.bigdata.local.cer",  "key": "/tmp/auto-tls/keys/master3.my.bigdata.local-key.pem" },
        { "hostname": "gateway1.my.bigdata.local", "certificate": "/tmp/auto-tls/certs/gateway1.my.bigdata.local.cer", "key": "/tmp/auto-tls/keys/gateway1.my.bigdata.local-key.pem" },
        { "hostname": "gateway2.my.bigdata.local", "certificate": "/tmp/auto-tls/certs/gateway2.my.bigdata.local.cer", "key": "/tmp/auto-tls/keys/gateway2.my.bigdata.local-key.pem" },
        { "hostname": "kms1.my.bigdata.local", "certificate": "/tmp/auto-tls/certs/kms1.my.bigdata.local.cer", "key": "/tmp/auto-tls/keys/kms1.my.bigdata.local-key.pem" },
        { "hostname": "kms2.my.bigdata.local", "certificate": "/tmp/auto-tls/certs/kms2.my.bigdata.local.cer", "key": "/tmp/auto-tls/keys/kms2.my.bigdata.local-key.pem" },
        { "hostname": "kts1.my.bigdata.local", "certificate": "/tmp/auto-tls/certs/kts1.my.bigdata.local.cer", "key": "/tmp/auto-tls/keys/kts1.my.bigdata.local-key.pem" },
        { "hostname": "kts2.my.bigdata.local", "certificate": "/tmp/auto-tls/certs/kts2.my.bigdata.local.cer", "key": "/tmp/auto-tls/keys/kts2.my.bigdata.local-key.pem" }  
    ]
  }' 'https://utility1.my.bigdata.local:7183/api/v45/cm/commands/addCustomCerts'
```

## Step 2: Generate Hosts CSV File

Create a CSV file containing all hostnames and their corresponding host IDs:

```bash
curl -sk -u admin:admin "https://utility1.my.bigdata.local:7183/api/v45/hosts" \
  | jq -r '.items[] | "\(.hostname),\(.hostId)"' > ~/hosts.csv
```

## Step 3: Create Certificate Deployment Script

Create the deployment script at `/root/script/generate_host_certs_v45.sh`:

```bash
#!/bin/bash

CM_HOST="utility1.my.bigdata.local"
CM_PORT="7183"
CM_USER="admin"
CM_PASS="admin"      # change if different

SSH_USER="root"
SSH_PASS="cloudera"
SSH_PORT=22

INPUT_FILE="$HOME/hosts.csv"

if [[ ! -f "$INPUT_FILE" ]]; then
  echo "ERROR: $INPUT_FILE not found."
  exit 1
fi

while IFS=, read -r hostname host_id
do
  # Skip empty lines
  [[ -z "$hostname" || -z "$host_id" ]] && continue

  echo "=== Generating host cert for ${hostname} (${host_id}) ==="

  curl -sk -u "${CM_USER}:${CM_PASS}" \
    -X POST \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "{ \"sshPort\" : ${SSH_PORT}, \"userName\" : \"${SSH_USER}\", \"password\" : \"${SSH_PASS}\" }" \
    "https://${CM_HOST}:${CM_PORT}/api/v45/hosts/${host_id}/commands/generateHostCerts"

  echo -e "\n"
done < "$INPUT_FILE"
```

Make the script executable:

```bash
chmod +x /root/script/generate_host_certs_v45.sh
```

## Step 4: Deploy Certificates to All Hosts

Execute the script to deploy certificates to all cluster hosts:

```bash
/root/script/generate_host_certs_v45.sh
```

## Verification

After completing these steps:

1. **Check certificate status** in Cloudera Manager web UI under Administration > Security
2. **Verify services** are running properly with new certificates
3. **Test TLS connections** to various services to ensure certificates are working

## Important Notes

- Replace default passwords (`admin`, `cloudera`) with your actual credentials
- Ensure certificate files exist at the specified paths on the Cloudera Manager server
- The script will process all hosts listed in the `hosts.csv` file
- Monitor the Cloudera Manager UI for any deployment errors
- Services may restart during certificate deployment - plan accordingly

## Troubleshooting

- If certificate upload fails, verify file paths and permissions
- If host certificate generation fails, check SSH connectivity and credentials
- Review Cloudera Manager logs for detailed error information
- Ensure all hosts are accessible and in good health before starting
