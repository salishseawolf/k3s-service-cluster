#!/bin/bash
set -euo pipefail

echo "Configuring log rotation..."

# Create directory for systemd journal configuration
mkdir -p /etc/systemd/journald.conf.d

# Configure systemd journal retention
cat > /etc/systemd/journald.conf.d/99-log-retention.conf << 'EOF'
[Journal]
# Limit journal size to 1GB
SystemMaxUse=1G
# Keep logs for 30 days
MaxRetentionSec=30d
# Compress logs older than 1 day
Compress=yes
EOF

# Configure logrotate for application logs
cat > /etc/logrotate.d/k3s-cluster << 'EOF'
# K3s and application log rotation
/var/log/k3s/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    create 0644 root root
}

# Cloud-init logs
/var/log/cloud-init*.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}

# Custom application logs (specific patterns to avoid conflicts)
/var/log/app/*.log
/var/log/custom/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    size 100M
}
EOF

# Create log directories if they don't exist
mkdir -p /var/log/k3s

# Set proper permissions
chmod 755 /var/log/k3s
chmod 644 /etc/logrotate.d/k3s-cluster

# Test logrotate configuration
echo "Testing logrotate configuration..."
logrotate -d /etc/logrotate.conf

# Restart systemd-journald to apply journal configuration
systemctl restart systemd-journald

echo "Log rotation configuration complete"
echo "- Journal retention: 30 days, max 1GB"
echo "- K3s logs: 30 days rotation"
echo "- Cloud-init logs: 4 weeks rotation"
echo "- Application logs: 7 days rotation with 100MB size limit"