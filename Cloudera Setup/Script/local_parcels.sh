#!/usr/bin/env bash
set -euo pipefail

# =====================================================
# Cloudera Runtime 7.3.1.700 Parcel Download Script
# Repo structure: cloudera-repos/cdh7/<version>/
# Target OS: RHEL 9.x
# =====================================================

USERNAME="<paywall-username>"
PASSWORD="<paywall-password>"

RUNTIME_VERSION="7.3.1.700"
BUILD_ID="74774806"

BASE_URL="https://archive.cloudera.com/p/cdh7/${RUNTIME_VERSION}/parcels"

# ✅ TARGET STRUCTURE YOU REQUESTED
TARGET_DIR="/var/www/html/cloudera-repos/cdh7/${RUNTIME_VERSION}"

mkdir -p "${TARGET_DIR}"
cd "${TARGET_DIR}"

echo "Downloading Cloudera Runtime ${RUNTIME_VERSION} parcels for EL9..."

PARCEL_NAME="CDH-7.3.1-1.cdh7.3.1.p700.${BUILD_ID}-el9.parcel"

# Download parcel
wget --show-progress \
  --user="${USERNAME}" --password="${PASSWORD}" \
  "${BASE_URL}/${PARCEL_NAME}"

# Download sha1
wget --show-progress \
  --user="${USERNAME}" --password="${PASSWORD}" \
  "${BASE_URL}/${PARCEL_NAME}.sha1"

# Download sha256
wget --show-progress \
  --user="${USERNAME}" --password="${PASSWORD}" \
  "${BASE_URL}/${PARCEL_NAME}.sha256"

# Download manifest
wget --show-progress \
  --user="${USERNAME}" --password="${PASSWORD}" \
  "${BASE_URL}/manifest.json"

# Permissions
chmod -R 755 /var/www/html/cloudera-repos/cdh7

SERVER_IP=$(hostname -I | awk '{print $1}')

echo
echo "========================================"
echo "Download complete."
echo
echo "Repo directory:"
echo "${TARGET_DIR}"
echo
echo "Parcel URL for Cloudera Manager:"
echo "http://${SERVER_IP}/cloudera-repos/cdh7/${RUNTIME_VERSION}/"
echo "========================================"
