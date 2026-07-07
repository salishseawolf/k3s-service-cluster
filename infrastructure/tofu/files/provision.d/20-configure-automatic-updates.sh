#!/bin/bash
set -euo pipefail

echo "Configuring automatic updates with staggered timing..."

# Install unattended-upgrades package
apt-get update
apt-get install -y unattended-upgrades apt-listchanges

# Get the last octet of private IP for staggering
PRIVATE_IP=$(ip route get 1.1.1.1 | grep -oP 'src \K[0-9.]+')
LAST_OCTET=$(echo "$PRIVATE_IP" | cut -d. -f4)
STAGGER_MINUTES=$(( (LAST_OCTET - 2) * 30 ))

# Calculate update time (11 AM UTC base + stagger)
UPDATE_HOUR=11
UPDATE_MINUTE=$STAGGER_MINUTES

# Handle minute overflow (max 23:59, wrap to next day if needed)
while [ $UPDATE_MINUTE -ge 60 ]; do
    UPDATE_HOUR=$(( UPDATE_HOUR + 1 ))
    UPDATE_MINUTE=$(( UPDATE_MINUTE - 60 ))
done

# Handle hour overflow (max 23, wrap to next day)
if [ $UPDATE_HOUR -ge 24 ]; then
    UPDATE_HOUR=$(( UPDATE_HOUR % 24 ))
fi

echo "Node will update at ${UPDATE_HOUR}:$(printf "%02d" $UPDATE_MINUTE) UTC"

# Configure unattended-upgrades
cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-updates";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

Unattended-Upgrade::Package-Blacklist {
    // Add packages to exclude if needed
};

Unattended-Upgrade::DevRelease "auto";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";

Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Unattended-Upgrade::Automatic-Reboot-Time "11:00";

Unattended-Upgrade::SyslogEnable "true";
Unattended-Upgrade::SyslogFacility "daemon";
Unattended-Upgrade::MailReport "never";
EOF

# Configure auto-upgrades with staggered timing
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

# Create systemd timer for staggered updates (overrides default)
cat > /etc/systemd/system/apt-daily-upgrade.timer << EOF
[Unit]
Description=Daily apt upgrade and clean activities
After=apt-daily.timer

[Timer]
OnCalendar=*-*-* ${UPDATE_HOUR}:$(printf "%02d" $UPDATE_MINUTE):00
RandomizedDelaySec=0
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Enable and start services
systemctl daemon-reload
systemctl enable unattended-upgrades
systemctl start unattended-upgrades
systemctl enable apt-daily-upgrade.timer
systemctl start apt-daily-upgrade.timer

# Test the configuration
unattended-upgrade --dry-run

echo "Automatic updates configured - updates at ${UPDATE_HOUR}:$(printf "%02d" $UPDATE_MINUTE) UTC"