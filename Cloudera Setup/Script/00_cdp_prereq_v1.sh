#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# Cloudera Prerequisites - RHEL 9.x
# - Runs sequentially (each section depends on previous)
# - Reboots ONCE at the end (after all configuration)
# ==========================================================

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: Run as root: sudo bash $0"
  exit 1
fi

REBOOT_REQUIRED=0
GRUB_CHANGED=0

################# 00- On All Hosts set hostnames ############################
# NOTE: Set per node manually before running OR uncomment and edit.
# hostnamectl set-hostname --static node.example.com


################# 01- Edit /etc/hosts on All Hosts ##########################
# Adds block only once (won't duplicate)
if ! grep -q "### CLOUDEA_HOSTS_BEGIN ###" /etc/hosts; then
  cat >> /etc/hosts <<'EOF'

### CLOUDEA_HOSTS_BEGIN ###
IP_ADDRESS_1   node1.example.com   node1
IP_ADDRESS_2   node2.example.com   node2
IP_ADDRESS_3   node3.example.com   node3
### CLOUDEA_HOSTS_END ###
EOF
fi


################# 02- Install Required Packages on All Hosts ################
dnf install -y \
  java-17-openjdk \
  java-17-openjdk-devel \
  nscd \
  sssd \
  chrony \
  rsyslog \
  wget \
  curl \
  bzip2 \
  tar \
  nc \
  zip \
  bind-utils \
  net-tools \
  telnet \
  vim \
  krb5-libs \
  krb5-workstation \
  openssl \
  openssl-devel \
  openldap-clients \
  openldap-devel \
  krb5-devel \
  systemd-devel \
  python3-pip

pip3 install --upgrade pip
pip3 install psycopg2-binary


################# 03- Disable SELinux on All Hosts ##########################
CONFIG_FILE="/etc/selinux/config"
if [[ -f "$CONFIG_FILE" ]]; then
  cp -a "$CONFIG_FILE" "$CONFIG_FILE.bak.$(date +%F_%H%M%S)"
  sed -i 's/^SELINUX=.*/SELINUX=permissive/' "$CONFIG_FILE"
  REBOOT_REQUIRED=1
else
  echo "WARN: $CONFIG_FILE not found"
fi


################ 04- Disable Firewall on All Hosts ##########################
systemctl disable --now firewalld 2>/dev/null || true
systemctl disable --now nftables 2>/dev/null || true


################ 05- Enable Syslog on All Hosts #############################
systemctl enable --now rsyslog


################ 06- Set ulimit on All Hosts ################################
cat > /etc/security/limits.d/99-cloudera.conf <<'EOF'
*               soft    nofile         1048576
*               hard    nofile         1048576
EOF
chmod 0644 /etc/security/limits.d/99-cloudera.conf


################ 07- PAM su file ############################################
# NOTE: Overwriting /etc/pam.d/su can break auth.
# Keeping your section, but not overwriting by default.
if [[ -f /etc/pam.d/su ]]; then
  echo "INFO: /etc/pam.d/su exists (not overwritten by this script)."
else
  echo "WARN: /etc/pam.d/su not found."
fi


################ 08- Set TCP Retries ########################################
################ 09- Disable IPv6 ###########################################
################ 10- Set vm.swappiness ######################################
################ 11- Overcommit Memory ######################################
cat > /etc/sysctl.d/99-cloudera.conf <<'EOF'
net.ipv4.tcp_retries2 = 5

net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

vm.swappiness = 1
vm.overcommit_memory = 1
EOF
chmod 0644 /etc/sysctl.d/99-cloudera.conf
sysctl --system


################ 12- Stop and disable unused services ########################
systemctl disable --now tuned 2>/dev/null || true
tuned-adm off 2>/dev/null || true
systemctl disable --now bluetooth 2>/dev/null || true
systemctl disable --now cups 2>/dev/null || true
systemctl disable --now fapolicyd 2>/dev/null || true


################ 13- Start and enable needed services ########################
systemctl enable --now chronyd
systemctl enable --now sssd
systemctl enable --now nscd


################ 14- Disable Transparent Huge Pages (runtime + persistence) ###
# Disable NOW (runtime)
echo never > /sys/kernel/mm/transparent_hugepage/enabled || true
echo never > /sys/kernel/mm/transparent_hugepage/defrag  || true

# ---- Restore your persistence method (thp_disable + rc.local) ----
rm -f /root/thp_disable
cat > /root/thp_disable <<'EOF'
#!/usr/bin/env bash
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag
sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1
sysctl -w net.ipv6.conf.lo.disable_ipv6=1
EOF
chmod +x /root/thp_disable

# Ensure rc.local exists and is executable
if [[ ! -f /etc/rc.d/rc.local ]]; then
  cat > /etc/rc.d/rc.local <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
fi
chmod +x /etc/rc.d/rc.local

# Add thp_disable call once
if ! grep -qF "/root/thp_disable" /etc/rc.d/rc.local; then
  echo "/root/thp_disable" >> /etc/rc.d/rc.local
fi

# Enable rc-local service on systemd (RHEL9)
if systemctl list-unit-files | grep -q '^rc-local\.service'; then
  systemctl enable rc-local.service 2>/dev/null || true
fi

# ---- Persist THP in GRUB (ONLY THP, NOT IPv6) ----
if [[ -d /etc/default/grub.d ]]; then
  if [[ ! -f /etc/default/grub.d/99-transparent-hugepage.cfg ]] || \
     ! grep -q "transparent_hugepage=never" /etc/default/grub.d/99-transparent-hugepage.cfg; then
    cat > /etc/default/grub.d/99-transparent-hugepage.cfg <<'EOF'
GRUB_CMDLINE_LINUX_DEFAULT="$GRUB_CMDLINE_LINUX_DEFAULT transparent_hugepage=never"
EOF
    chmod 0644 /etc/default/grub.d/99-transparent-hugepage.cfg
    REBOOT_REQUIRED=1
    GRUB_CHANGED=1
  fi
  grubby --update-kernel=ALL --args="transparent_hugepage=never"
else
  if [[ -f /etc/default/grub ]]; then
    # remove ipv6.disable=1 if present (as you requested)
    # if grep -q "ipv6.disable=1" /etc/default/grub; then
    #   cp -a /etc/default/grub /etc/default/grub.bak.$(date +%F_%H%M%S)
    #   sed -i -E 's/[[:space:]]ipv6\.disable=1//g' /etc/default/grub
    #   chmod 0644 /etc/default/grub
    #   GRUB_CHANGED=1
    #   REBOOT_REQUIRED=1
    # fi

    # add THP if missing
    if ! grep -q "transparent_hugepage=never" /etc/default/grub; then
      cp -a /etc/default/grub /etc/default/grub.bak.$(date +%F_%H%M%S)
      sed -i -E 's/^(GRUB_CMDLINE_LINUX="[^"]*)(")/\1 transparent_hugepage=never\2/' /etc/default/grub
      chmod 0644 /etc/default/grub
      REBOOT_REQUIRED=1
      GRUB_CHANGED=1
    fi
    grubby --update-kernel=ALL --args="transparent_hugepage=never"
  else
    echo "WARN: /etc/default/grub not found - cannot persist THP setting."
  fi
fi

# Rebuild GRUB only if GRUB was changed
if [[ "${GRUB_CHANGED}" -eq 1 ]]; then
  grub2-mkconfig -o /boot/grub2/grub.cfg >/dev/null
fi


################ 15- Disable nscd cache on All Hosts #########################
NSCD_CONFIG="/etc/nscd.conf"
if [[ -f "$NSCD_CONFIG" ]]; then
  cp -a "$NSCD_CONFIG" "$NSCD_CONFIG.bak.$(date +%F_%H%M%S)"
else
  touch "$NSCD_CONFIG"
fi

cat > /etc/nscd.conf <<'EOF'
server-user nscd
debug-level 0
paranoia no

enable-cache passwd no
enable-cache group  no
enable-cache services no
enable-cache netgroup no

enable-cache hosts yes
positive-time-to-live hosts 3600
negative-time-to-live hosts 20
EOF

chmod 0644 /etc/nscd.conf
systemctl restart nscd || true
systemctl enable nscd || true


################ 16- Kernel parameters check on All Hosts ####################
echo
echo "======== CHECKS ========"
echo "SELinux (getenforce):"
getenforce || true
echo
echo "THP (runtime):"
cat /sys/kernel/mm/transparent_hugepage/enabled || true
cat /sys/kernel/mm/transparent_hugepage/defrag  || true
echo
echo "IPv6 sysctl:"
sysctl net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6 net.ipv6.conf.lo.disable_ipv6 || true
echo
echo "Sysctl values:"
sysctl net.ipv4.tcp_retries2 vm.swappiness vm.overcommit_memory || true
echo "========================"
echo


################ FINAL - Reboot once at end ##################################
if [[ "${REBOOT_REQUIRED}" -eq 1 ]]; then
  echo "INFO: Reboot is required to apply GRUB/SELinux changes."
  echo "INFO: Rebooting now..."
  sleep 3
  reboot
else
  echo "INFO: No reboot required (but reboot is still recommended)."
fi
