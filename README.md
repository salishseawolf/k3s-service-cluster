# K3s Service Cluster - Hetzner Cloud K3s Infrastructure

High-Availability Kubernetes cluster infrastructure provisioning using 
OpenTofu and Hetzner Cloud.

## Project Structure

```
/workspace/
├── infrastructure/tofu/       # Layer 1: Cloud provisioning (OpenTofu)
├── platform/                  # Layer 2: K3s cluster + platform services
│   ├── ansible/               # Cluster deployment
│   └── charts/                # Helm charts (cert-manager, step-ca)
└── services/                  # Layer 3: Application services
    ├── database/              # CloudNativePG PostgreSQL
    ├── identity/              # Authentik
    ├── seaweedfs/             # SeaweedFS distributed storage (S3 + filer)
    ├── seaweedfs-csi/         # SeaweedFS CSI driver for dynamic PVC provisioning
    ├── gatus/                 # Health monitoring dashboard
    └── developer-tooling/     # Developer tools on nodes
```

## Prerequisites

1. **Hetzner Cloud Account** with API token
2. **SSH Key** uploaded to Hetzner Cloud 
3. **mise** for tool management: https://mise.jdx.dev/
4. **1Password CLI** for secure secret management

## Setup

### 1. Install Tools
```bash
# Install mise if not already installed
curl https://mise.run | sh

# Install project tools
mise install
```

### 2. Configure Secrets

Secrets are split into two sources:

**Shared infrastructure secrets** (in `mise.toml` files, committed as `op://` references):
- **Hetzner Cloud Token**: `op://Employee/Hetzner/api_token` (via `.secrets.env`)
- **SSH Key Name**: `op://Employee/Hetzner/ssh_key_name`
- **K3s Cluster Token**: `op://K3s Service Cluster/K3s Service Cluster/credential`
- **K3s etcd Secret**: `op://K3s Service Cluster/K3s Service Cluster/etcd_secret`
- **Cloudflare config**: `op://Employee/K3s Service Cluster Cloudflare DNS Token/credential`

These require 1Password CLI and a shared vault.

**Personal / deployment-specific secrets** (in `.secrets.env`, gitignored):

Each developer stores their own API tokens in 1Password and references them
via `op://` paths in `.secrets.env`. This file is loaded automatically by
mise via `_.file = ".secrets.env"` in the root `mise.toml`. The `op://`
references are resolved at runtime by `op run`.

##### 1. Hetzner Cloud API token

1. Log into the [Hetzner Cloud Console](https://console.hetzner.cloud/).
2. Go to **Security → API Tokens** in the left sidebar.
3. Click **Generate API Token**.
4. Give it a descriptive name (e.g. `k3s-service-cluster`) and leave
   the permission at the default **Read & Write** (the project needs to
   create and manage servers, networks, load balancers, and firewalls).
5. Click **Create API Token** and copy the token immediately — it won't be
   shown again.
6. Store it in 1Password:
   - Open the **1Password app** or `eval $(op signin)`.
   - Create a new item in the `Employee` vault with title `Hetzner` and a
     field named `api_token` containing the token value.

##### 2. Cloudflare API token

1. Log into the [Cloudflare Dashboard](https://dash.cloudflare.com/).
2. Click the user icon (top-right) → **My Profile** → **API Tokens**.
3. Click **Create Token**.
4. Choose **Create Custom Token**.
5. Configure the token:
   - **Token name**: something descriptive (e.g. `k3s-cert-manager-dns01`).
   - **Permissions**: `Zone` / `DNS` / `Edit`.
   - **Zone Resources**: `Include` / `Specific zone` / (select your domain).
6. Click **Continue to summary**, then **Create Token**. Copy the token
   immediately.
7. Store it in 1Password:
   - Open the **1Password app** or `eval $(op signin)`.
   - Create a new item in the `Employee` vault with title
     `K3s Service Cluster Cloudflare DNS Token` and a field named
     `credential` containing the token value.

##### 3. Reference in `.secrets.env`

Create `.secrets.env` at the project root with `op://` references pointing to
the 1Password items you just created:

```env
# Personal / deployment-specific secrets and infra credentials
# These are sourced by mise via env._.file in root mise.toml
# (not committed to git — .secrets.env in .gitignore)
#
# 1Password references are resolved at runtime by `op run`.

HCLOUD_TOKEN=op://Employee/Hetzner/api_token
TF_VAR_cloudflare_api_token=op://Employee/K3s Service Cluster Cloudflare DNS Token/credential
```

These references are safe to commit, but `.secrets.env` is gitignored so each
developer maintains their own copy. See the `mise.toml` files for additional
`op://` shared secrets that don't need individual setup.

### 3. Initialize Infrastructure
```bash
mise run setup
```

This will:
- Install all project tools via mise
- Initialize OpenTofu backend
- Install required Ansible collections

## Infrastructure Overview

### Resources Provisioned
- **3x Hetzner Cloud Servers** (cx33, Debian 12)
  - `k3s-converged-node-01` (192.168.1.2)
  - `k3s-converged-node-02` (192.168.1.3)
  - `k3s-converged-node-03` (192.168.1.4)
  - Labeled: `project=k3s-service-cluster`, `environment=production`, `role=k3s-node`
- **Private Network** (192.168.0.0/16, labeled for CCM discovery)
- **Load Balancer** (for K3s API HA endpoint)
- **Cloud Firewall** (restricted access)

### Kubernetes Components
- **K3s** (v1.31.4+k3s1) - Lightweight Kubernetes distribution
- **Flannel** (wireguard-native) - CNI with encrypted node traffic
- **Hetzner Cloud Controller Manager** - Node lifecycle and LoadBalancer provisioning (auto-deployed with K3s)
- **Hetzner CSI Driver** - Persistent volume provisioning (auto-deployed with K3s)
- **cert-manager** - TLS certificate management with Let's Encrypt
- **Traefik** - Ingress controller (DaemonSet with HostPort)
- **etcd encryption** - Secrets encrypted at rest with AES-CBC

### Security Configuration
- SSH access restricted to admin IP
- Password authentication disabled
- Firewalld configured on each node
- Fail2ban installed for intrusion prevention

### Network Access
- **SSH (22)**: Admin IP only
- **K8s API (6443)**: Admin IP only  
- **HTTP/HTTPS (80/443)**: Admin IP + private network
- **Internal**: Full access within private network

## Usage

### Infrastructure Operations (Layer 1)
```bash
# Plan changes (always run first)
mise run //infrastructure/tofu:plan

# Deploy infrastructure
mise run //infrastructure/tofu:apply

# Destroy infrastructure
mise run //infrastructure/tofu:destroy

# Validate configuration
mise run //infrastructure/tofu:validate

# Format code
mise run //infrastructure/tofu:fmt

# Lint and validate
mise run //infrastructure/tofu:check

# Replace all nodes with updated cloud-init configuration
mise run //infrastructure/tofu:replace-nodes

# Get node IP by index (0, 1, or 2)
mise run //infrastructure/tofu:ip 0
```

### Platform Operations (Layer 2)
```bash
# Deploy K3s cluster with Hetzner integrations
mise run //platform/ansible:deploy

# Deploy K3s cluster only (no integrations)
mise run //platform/ansible:deploy:cluster

# Test connectivity
mise run //platform/ansible:ping

# List inventory
mise run //platform/ansible:inventory

# Update SSH known_hosts
mise run //platform/ansible:update-known-hosts

# Uninstall K3s
mise run //platform/ansible:uninstall

# Deploy cert-manager
mise run //platform/charts/cert-manager:apply

# Check cert-manager status
mise run //platform/charts/cert-manager:status
```

### Service Operations (Layer 3)
```bash
# Deploy individual services
mise run //services/database:deploy
mise run //services/identity:deploy
mise run //services/seaweedfs:deploy
mise run //services/seaweedfs-csi:deploy
mise run //services/gatus:deploy
mise run //services/developer-tooling:deploy
```

### Full Stack Deployment
```bash
# Deploy everything with a single 1Password prompt
mise run deploy
```

This runs: infrastructure -> K3s cluster (with auto-deployed CCM/CSI) -> cert-manager -> Step-CA -> services

### SeaweedFS Storage

Storage services in the `services/` layer:

- **SeaweedFS** (`//services/seaweedfs`) — Distributed file storage with S3 API, filer UI (Authentik-protected), PostgreSQL-backed metadata, and automated PVC backups to Hetzner Object Storage.
- **SeaweedFS CSI Driver** (`//services/seaweedfs-csi`) — Container Storage Interface driver enabling dynamic PVC provisioning backed by SeaweedFS filer volumes. Workloads use it by adding `storageClassName: seaweedfs-storage` to their PVC specs.

```bash
# Deploy storage stack
mise run //services/seaweedfs:deploy
mise run //services/seaweedfs-csi:deploy

# Create a PVC with seaweedfs storage
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-volume
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
  storageClassName: seaweedfs-storage
EOF
```

### SSH Access
```bash
# SSH into first node (default)
mise run ssh

# SSH into specific node (0, 1, or 2)
mise run ssh 1
mise run ssh:k3s 2
```

### Validation
```bash
# Run all checks across all layers
mise run check

# Format all code
mise run fmt
```

### K3s Deployment Verification

After deploying the cluster, verify it's healthy:

```bash
# Set up kubectl access (automatic for mise tasks)
export KUBECONFIG=./kubeconfig

# Check cluster health
kubectl get nodes -o wide
kubectl cluster-info

# Verify Hetzner CCM is running
kubectl get pods -n kube-system -l app=hcloud-cloud-controller-manager

# Test LoadBalancer provisioning
kubectl create deployment test-nginx --image=nginx
kubectl expose deployment test-nginx --type=LoadBalancer --port=80
kubectl get svc test-nginx -w  # Wait for EXTERNAL-IP
kubectl delete deployment,svc test-nginx
```

### Development Workflow
```bash
# Install pre-commit hooks
pre-commit install

# Run pre-commit on all files
pre-commit run --all-files
```

## Configuration Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `hcloud_token` | - | Hetzner Cloud API token (from 1Password) |
| `ssh_key_name` | - | Name of SSH key in Hetzner Cloud (from 1Password) |
| `k3s_token` | - | K3s cluster token for node authentication (from 1Password) |
| `server_type` | `cx33` | Hetzner server type (overridden from `cx23` default by mise) |
| `allowed_admin_cidr` | `73.97.54.81/32` | Admin access CIDR |
| `location` | `hel1` | Hetzner datacenter location |
| `network_zone` | `eu-central` | Network zone for resources |
| `k3s_version` | `v1.31.4+k3s1` | K3s version to install |

## Outputs

After deployment, retrieve connection details:
```bash
# Get node public IPs
mise run -q //infrastructure/tofu:output:json | jq '.node_public_ips.value'

# Get node private IPs
mise run -q //infrastructure/tofu:output:json | jq '.node_private_ips.value'

# Get Load Balancer IP (control plane endpoint)
mise run -q //infrastructure/tofu:output:json | jq '.load_balancer_ip.value'
```

## Server Access

### SSH into Nodes
After infrastructure deployment, connect to any node:
```bash
mise run ssh 0
mise run ssh 1
mise run ssh 2
```

**Connection Notes:**
- SSH access only works from the configured admin IP
- SSH authentication uses 1Password SSH agent (no private key files)
- Default user is `root` on Debian 12 instances
- SSH fingerprints are automatically updated in `~/.ssh/known_hosts` when infrastructure changes

## Updating Cloud-Init Configuration

When you modify `cloud-init.yaml`, the changes only apply to newly created servers:

### Option 1: Recreate All Servers (Recommended)
```bash
# Force recreation of all servers with new cloud-init
mise run //infrastructure/tofu:replace-nodes

# Verify connectivity
mise run //platform/ansible:ping
```

**Note:** This will cause downtime as servers are recreated. It automatically
clears the Ansible fact cache, recreates all three servers, re-registers
nodes with the Load Balancer, and updates SSH fingerprints.

### Option 2: Use Ansible for Runtime Changes
For configuration changes that don't require server recreation, edit the
relevant Ansible playbook or role and re-run the deploy:

```bash
mise run //platform/ansible:deploy
```

### Option 3: Manual Application
SSH into each node and apply changes directly:

```bash
mise run ssh 0
mise run ssh 1
mise run ssh 2
```

## Security Notes

- Pod Security Admission enforces "restricted" policy
- etcd secrets encrypted at rest with Secretbox (XSalsa20-Poly1305)
- Node traffic encrypted via Flannel wireguard-native
- TLS certificates managed by cert-manager with Let's Encrypt
- All firewall rules use allow-list approach
