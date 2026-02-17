#!/bin/bash

USER="cdpadmin"
PASS="Admin&P@ssw0rd"

# create user
useradd -m $USER

# set password
echo "$USER:$PASS" | chpasswd

# give passwordless sudo
echo "$USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$USER

# fix permissions
chmod 0440 /etc/sudoers.d/$USER

echo "User created with passwordless sudo"
