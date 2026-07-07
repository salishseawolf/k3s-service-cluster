#!/bin/bash
set -euo pipefail

echo "Setting up system services..."

# Restart SSH service to apply new configuration
systemctl restart sshd

# Enable and start open-iscsi for storage
systemctl enable open-iscsi
systemctl start open-iscsi

echo "System services setup complete"