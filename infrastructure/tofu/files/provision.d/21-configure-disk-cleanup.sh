#!/bin/bash
set -euo pipefail

echo "Configuring automatic disk cleanup..."

# Create disk cleanup script
cat > /usr/local/bin/disk-cleanup.sh << 'EOF'
#!/bin/bash
set -euo pipefail

# Disk cleanup script for automated maintenance
echo "Starting automated disk cleanup at $(date)"

# Clean package cache
echo "Cleaning package cache..."
apt-get autoremove -y
apt-get autoclean
apt-get clean

# Clean temporary files older than 7 days
echo "Cleaning temporary files..."
find /tmp -type f -atime +7 -delete 2>/dev/null || true
find /var/tmp -type f -atime +7 -delete 2>/dev/null || true

# Clean old kernels (keep current + 1 previous)
echo "Cleaning old kernels..."
if command -v apt-mark >/dev/null; then
    OLD_KERNELS=$(dpkg -l | grep -E 'linux-image-[0-9]' | grep -v "$(uname -r)" | awk '{print $2}' | head -n -1)
    if [ -n "$OLD_KERNELS" ]; then
        echo "Removing old kernels: $OLD_KERNELS"
        apt-get purge -y $OLD_KERNELS || true
    fi
fi

# Clean Docker if installed
if command -v docker >/dev/null; then
    echo "Cleaning Docker resources..."
    docker system prune -af --volumes || true
fi

# Clean cloud-init cache (but preserve logs for log rotation script)
echo "Cleaning cloud-init cache..."
rm -rf /var/lib/cloud/instances/* 2>/dev/null || true

# Report disk usage
echo "Disk usage after cleanup:"
df -h /

echo "Disk cleanup completed at $(date)"
EOF

# Make cleanup script executable
chmod +x /usr/local/bin/disk-cleanup.sh

# Create systemd service for disk cleanup
cat > /etc/systemd/system/disk-cleanup.service << 'EOF'
[Unit]
Description=Automated disk cleanup service
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/disk-cleanup.sh
User=root
StandardOutput=journal
StandardError=journal
EOF

# Create systemd timer for weekly cleanup (Sundays at 1 AM Pacific = 8 AM UTC)
cat > /etc/systemd/system/disk-cleanup.timer << 'EOF'
[Unit]
Description=Weekly automated disk cleanup
Requires=disk-cleanup.service

[Timer]
OnCalendar=Sun *-*-* 08:00:00
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Enable and start the timer
systemctl daemon-reload
systemctl enable disk-cleanup.timer
systemctl start disk-cleanup.timer

# Run initial cleanup
echo "Running initial disk cleanup..."
/usr/local/bin/disk-cleanup.sh

echo "Disk cleanup configuration complete - scheduled for Sundays at 1 AM Pacific"