#!/bin/bash
set -euo pipefail

echo "Configuring firewalld..."

# Enable and start firewalld
systemctl enable firewalld
systemctl start firewalld

# Detect public interface (the one used for default route)
PUBLIC_IF=$(ip -4 route show default | head -1 | awk '{print $5}')

# Detect private interface (the one with IP in 192.168.0.0/16 range)
PRIVATE_IF=$(ip -4 addr show | awk '/inet 192.168/ {print $NF}')

echo "Detected public interface: ${PUBLIC_IF}"
echo "Detected private interface: ${PRIVATE_IF}"

# --- PUBLIC ZONE (External Traffic) ---
echo "Configuring public zone..."
firewall-cmd --permanent --zone=public --add-interface="${PUBLIC_IF}"
firewall-cmd --permanent --zone=public --add-service=ssh
firewall-cmd --permanent --zone=public --add-service=http
firewall-cmd --permanent --zone=public --add-service=https

# Allow Kubernetes API (6443/tcp)
# Note: 'kube-apiserver' is not a standard firewalld service, so we use the port.
firewall-cmd --permanent --zone=public --add-port=6443/tcp

# Allow Gitea SSH (2222/tcp)
firewall-cmd --permanent --zone=public --add-port=2222/tcp

# --- TRUSTED ZONE (Internal/Cluster Traffic) ---
# 1. Trust the Physical Private Network (Node-to-Node communication)
if [ -n "${PRIVATE_IF}" ]; then
  echo "Adding private interface ${PRIVATE_IF} to trusted zone"
  firewall-cmd --permanent --zone=trusted --add-interface="${PRIVATE_IF}"
  # Allow WireGuard traffic (UDP 51820) between nodes
  firewall-cmd --permanent --zone=trusted --add-service=wireguard
else
  echo "Warning: Could not detect private network interface"
fi

# 2. Trust the Virtual Kubernetes Interfaces (Pod-to-Pod communication)
# CRITICAL FIX: This prevents "No route to host" errors inside the cluster.
# Firewalld must trust the interfaces K3s creates for the overlay network.
echo "Adding K3s/CNI interfaces to trusted zone..."
firewall-cmd --permanent --zone=trusted --add-interface=cni0
firewall-cmd --permanent --zone=trusted --add-interface=flannel.1
firewall-cmd --permanent --zone=trusted --add-interface=flannel-wg

# Apply changes
firewall-cmd --reload

echo "Firewall configuration complete"
