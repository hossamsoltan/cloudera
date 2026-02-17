#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# PostgreSQL 16 Install + Cloudera Databases (RHEL 9)
# - TLS/SSL: disabled
# - JDBC: skipped (already exists)
# - Password policy: <username>@123
# - Creates roles + databases for: scm, rman, hue, hive, oozie,
#   ranger (rangeradmin), rangerkms, schemaregistry, yqm, smm, das
# ============================================================

echo "============================================================"
echo " PostgreSQL 16 + Cloudera DB bootstrap (RHEL 9)"
echo " TLS: OFF | JDBC: SKIPPED | Passwords: <user>@123"
echo "============================================================"

# -----------------------------
# 0) Pre-req: must run as root
# -----------------------------
if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: Run as root."
  exit 1
fi

# -----------------------------
# 1) Install PGDG repo + PG16
# -----------------------------
dnf install -y \
  https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm

dnf -qy module disable postgresql

dnf install -y \
  postgresql16 \
  postgresql16-server \
  postgresql16-libs \
  postgresql16-contrib

# -----------------------------
# 2) Locale for UTF-8
# -----------------------------
if ! grep -q '^LC_ALL=' /etc/locale.conf 2>/dev/null; then
  echo 'LC_ALL="C.UTF-8"' >> /etc/locale.conf
fi
export LC_ALL=C.UTF-8

# -----------------------------
# 3) Init DB (only if not already)
# -----------------------------
PGDATA="/var/lib/pgsql/16/data"
if [[ ! -f "${PGDATA}/PG_VERSION" ]]; then
  /usr/pgsql-16/bin/postgresql-16-setup initdb
else
  echo "PGDATA already initialized: ${PGDATA}"
fi

# -----------------------------
# 4) Configure postgresql.conf
# -----------------------------
conf="${PGDATA}/postgresql.conf"
hba="${PGDATA}/pg_hba.conf"

timestamp="$(date +%F_%H%M%S)"

cp -a "$conf" "${conf}.bak.${timestamp}"
cp -a "$hba"  "${hba}.bak.${timestamp}"

# Ensure these settings are set (append if missing, replace if present)
set_conf() {
  local key="$1"
  local value="$2"
  if grep -Eq "^[#[:space:]]*${key}[[:space:]]*=" "$conf"; then
    sed -ri "s|^[#[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "$conf"
  else
    echo "${key} = ${value}" >> "$conf"
  fi
}

set_conf "listen_addresses" "'*'"
set_conf "port" "5432"
set_conf "max_connections" "1000"
set_conf "shared_buffers" "1024MB"
set_conf "wal_buffers" "16MB"
set_conf "max_wal_size" "6GB"
set_conf "min_wal_size" "512MB"
set_conf "checkpoint_completion_target" "0.9"
set_conf "standard_conforming_strings" "off"
set_conf "jit" "off"
set_conf "ssl" "off"

# -----------------------------
# 5) Configure pg_hba.conf (MD5)
# -----------------------------
cat > "$hba" <<'EOF'
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# Local unix socket
local   all             all                                     peer

# Localhost IPv4/IPv6
host    all             all             127.0.0.1/32            md5
host    all             all             ::1/128                 md5

# Remote access (adjust CIDR if you want to restrict)
host    all             all             0.0.0.0/0               md5
EOF

chown -R postgres:postgres /var/lib/pgsql/16
chmod 700 "$PGDATA"

# -----------------------------
# 6) Start/Enable service
# -----------------------------
systemctl enable postgresql-16
systemctl restart postgresql-16

echo
echo "PostgreSQL service status:"
systemctl --no-pager --full status postgresql-16 || true

echo
echo "Listening check:"
ss -lntp | grep -E ':5432' || true

# -----------------------------
# 7) Create roles + DBs (idempotent)
# -----------------------------
create_role_sql() {
  local r="$1"
  printf "%s\n" "DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='${r}') THEN
    CREATE ROLE ${r} LOGIN PASSWORD '${r}@123';
  END IF;
END \$\$;"
}

create_db_gexec_sql() {
  local db="$1"
  local owner="$2"
  # Generates CREATE DATABASE statement only when missing, then executes via \gexec
  printf "%s\n" "SELECT format('CREATE DATABASE %I OWNER %I ENCODING %L;', '${db}', '${owner}', 'UTF8')
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname='${db}')
\\gexec"
}

grant_sql() {
  local db="$1"
  local owner="$2"
  printf "%s\n" "GRANT ALL PRIVILEGES ON DATABASE ${db} TO ${owner};"
}

echo
echo "Creating Cloudera roles & databases..."

sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
-- postgres password per policy
ALTER USER postgres PASSWORD 'postgres@123';

-- Roles
$(create_role_sql scm)
$(create_role_sql rman)
$(create_role_sql hue)
$(create_role_sql hive)
$(create_role_sql oozie)
$(create_role_sql rangeradmin)
$(create_role_sql rangerkms)
$(create_role_sql schemaregistry)
$(create_role_sql yqm)
$(create_role_sql smm)
$(create_role_sql das)

-- Databases (must NOT be inside DO; use \gexec)
$(create_db_gexec_sql scm scm)
$(create_db_gexec_sql rman rman)
$(create_db_gexec_sql hue hue)
$(create_db_gexec_sql hive hive)
$(create_db_gexec_sql oozie oozie)
$(create_db_gexec_sql ranger rangeradmin)
$(create_db_gexec_sql rangerkms rangerkms)
$(create_db_gexec_sql schemaregistry schemaregistry)
$(create_db_gexec_sql yqm yqm)
$(create_db_gexec_sql smm smm)
$(create_db_gexec_sql das das)

-- Grants (safe to re-run)
$(grant_sql scm scm)
$(grant_sql rman rman)
$(grant_sql hue hue)
$(grant_sql hive hive)
$(grant_sql oozie oozie)
$(grant_sql ranger rangeradmin)
$(grant_sql rangerkms rangerkms)
$(grant_sql schemaregistry schemaregistry)
$(grant_sql yqm yqm)
$(grant_sql smm smm)
$(grant_sql das das)

-- Per Cloudera guide
ALTER DATABASE hive  SET standard_conforming_strings=off;
ALTER DATABASE oozie SET standard_conforming_strings=off;

SELECT 'OK - roles & databases ensured' AS status;
SQL

echo
echo "============================================================"
echo "DONE"
echo "PGDATA: ${PGDATA}"
echo "Passwords: <user>@123 (example: scm@123, hive@123, postgres@123)"
echo "============================================================"

echo
echo "Useful checks:"
echo "  sudo -u postgres psql -c \"\\du\""
echo "  sudo -u postgres psql -c \"\\l\""
echo "  psql -h localhost -U postgres -d postgres"
