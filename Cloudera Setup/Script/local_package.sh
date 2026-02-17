#!/usr/bin/env bash
set -euo pipefail

# =====================================================
# Cloudera Manager 7 Repo Tarball + CM API Swagger Download
# Repo structure: /cm7/<FULL_VERSION>/
# =====================================================

# ------------------------------
# 1) Cloudera Archive Credentials
# ------------------------------
USERNAME="<paywall-username>"
PASSWORD="<paywall-password>"

# ------------------------------
# 2) Versions
# ------------------------------
CM_VERSION="7.13.1.700"
CM_API_VERSION="7.13.1"

# ------------------------------
# 3) OS tarball
# ------------------------------
OS_TARBALL="cm${CM_VERSION}-redhat9.tar.gz"

# ------------------------------
# 4) Paths
# ------------------------------
WEBROOT="/var/www/html/cloudera-repos/cm7"
VERSION_DIR="${WEBROOT}"
#VERSION_DIR="${WEBROOT}/${CM_VERSION}"

WORKDIR="/tmp/cloudera_cm7_repo"

REPO_URL_BASE="https://archive.cloudera.com/p/cm7/${CM_VERSION}/repo-as-tarball"

SWAGGER_DIR="/opt/cloudera/swagger"
CM_API_URL_BASE="https://archive.cloudera.com/p/cm7/${CM_VERSION}/generic/jar/cm_api"
CM_API_TAR="cloudera-manager-api-swagger-${CM_API_VERSION}.tar"

# ------------------------------
# 5) Install Apache
# ------------------------------
dnf install -y httpd mod_ssl wget tar coreutils || true
systemctl enable --now httpd

mkdir -p "${VERSION_DIR}"
mkdir -p "${WORKDIR}"
mkdir -p "${SWAGGER_DIR}"

cd "${WORKDIR}"

# ------------------------------
# 6) Download repo tarball
# ------------------------------
echo "Downloading CM repo ${CM_VERSION}..."

wget --show-progress \
  --user="${USERNAME}" --password="${PASSWORD}" \
  "${REPO_URL_BASE}/${OS_TARBALL}"

# ------------------------------
# 7) Verify checksum (SHA256 preferred)
# ------------------------------
if wget -q --user="${USERNAME}" --password="${PASSWORD}" \
  "${REPO_URL_BASE}/${OS_TARBALL}.sha256"; then

  sha256sum -c "${OS_TARBALL}.sha256"

fi

# ------------------------------
# 8) Extract into version directory
# ------------------------------
echo "Extracting into ${VERSION_DIR}..."

tar xvf "${OS_TARBALL}" -C "${VERSION_DIR}"

# ------------------------------
# 9) Remove tar file to save space
# ------------------------------
rm -f "${OS_TARBALL}"

# ------------------------------
# 10) Set permissions
# ------------------------------
chmod -R 755 "${WEBROOT}"

# ------------------------------
# 11) Download Swagger
# ------------------------------
wget --show-progress \
  --user="${USERNAME}" --password="${PASSWORD}" \
  -O "${SWAGGER_DIR}/${CM_API_TAR}" \
  "${CM_API_URL_BASE}/${CM_API_TAR}"

tar -xvf "${SWAGGER_DIR}/${CM_API_TAR}" -C "${SWAGGER_DIR}"

chmod -R 755 "${SWAGGER_DIR}"

# ------------------------------
# 12) Final output
# ------------------------------
SERVER_IP=$(hostname -I | awk '{print $1}')

echo
echo "=================================================="
echo "CM7 repo installed successfully"
echo
echo "Repo location:"
echo "  ${VERSION_DIR}"
echo
echo "Repo URL:"
echo "  http://${SERVER_IP}/cloudera-repos/cm7/${CM_VERSION}/"
echo
echo "Swagger location:"
echo "  ${SWAGGER_DIR}"
echo "=================================================="
