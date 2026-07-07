#!/bin/bash
set -euo pipefail

echo "Configuring fail2ban for systemd journal..."

# Create fail2ban configuration for systemd journal with firewalld
cat > /etc/fail2ban/jail.d/defaults-debian.conf << 'EOF'
[DEFAULT]
banaction = firewallcmd-multiport

[sshd]
enabled = true
filter = sshd
backend = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd
bantime = 1h
findtime = 10m
maxretry = 3
EOF

# Ensure fail2ban can read journal
usermod -a -G systemd-journal fail2ban

echo "Restarting fail2ban with systemd journal backend..."
systemctl restart fail2ban
systemctl enable fail2ban

# Verify configuration
echo "Verifying fail2ban status..."
sleep 2
fail2ban-client status sshd

echo "fail2ban configuration complete"