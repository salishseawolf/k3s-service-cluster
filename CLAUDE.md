# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is Phase 1 of the K3s Service Cluster - a High-Availability Kubernetes cluster infrastructure provisioning system using OpenTofu and Hetzner Cloud. The project uses a three-layer monorepo architecture.

## Architecture

### Three-Layer Structure
```
/workspace/
├── infrastructure/          # Layer 1: Cloud provisioning (OpenTofu)
│   └── tofu/
├── platform/               # Layer 2: K3s cluster + platform services
│   ├── ansible/            # Cluster deployment
│   └── charts/             # Helm charts (cert-manager)
├── services/               # Layer 3: Application services
    ├── database/           # CloudNativePG PostgreSQL
    ├── redis/              # Redis (shared cache/session store)
    ├── identity/           # Authentik
    ├── seaweedfs/          # SeaweedFS distributed storage
    ├── seaweedfs-csi/      # SeaweedFS CSI driver
    ├── copyparty/          # Copyparty file sharing
    ├── gatus/              # Gatus monitoring
    └── developer-tooling/  # Developer tools
```

### Infrastructure Stack
- **Cloud Provider**: Hetzner Cloud (hel1 region)
- **Infrastructure as Code**: OpenTofu (in `/infrastructure/tofu/`)
- **Configuration Management**: Ansible with Hetzner Cloud dynamic inventory
- **Kubernetes**: 3-node K3s HA cluster with embedded etcd
- **Cloud Controller**: Hetzner CCM for LoadBalancer services and node lifecycle
- **CSI Driver**: Hetzner CSI for persistent volumes
- **HA Endpoint**: Hetzner Load Balancer for K3s API
- **Secret Management**: 1Password CLI integration via `op run`

### Resource Design
- **Networking**: Private network (192.168.0.0/16) with cloud subnet (192.168.1.0/24)
- **Compute**: 3x cx33 servers with static private IPs (.2, .3, .4)
- **Server Labels**: `project=k3s-service-cluster`, `environment=production`, `role=k3s-node`, `node_index`
- **HA Setup**: Hetzner Load Balancer fronts K3s API on port 6443

## Essential Commands

### Project Setup
```bash
# Initial setup
mise run setup

# Install tools only
mise install
```

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
mise run //services/redis:deploy
mise run //services/identity:deploy
mise run //services/seaweedfs:deploy
mise run //services/seaweedfs-csi:deploy
mise run //services/copyparty:deploy
mise run //services/gatus:deploy
mise run //services/developer-tooling:deploy
```

### Full Stack Deployment
```bash
# Deploy everything with a single 1Password prompt
mise run deploy
```

This runs: infrastructure -> K3s cluster -> Hetzner integrations -> cert-manager -> step-ca -> all services

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

## Task Mapping (Old -> New)

| Old Command | New Command |
|-------------|-------------|
| `mise run tofu:plan` | `mise run //infrastructure/tofu:plan` |
| `mise run tofu:apply` | `mise run //infrastructure/tofu:apply` |
| `mise run tofu:destroy` | `mise run //infrastructure/tofu:destroy` |
| `mise run tofu:ip 0` | `mise run //infrastructure/tofu:ip 0` |
| `mise run ansible:deploy-k3s` | `mise run //platform/ansible:deploy` |
| `mise run ansible:deploy-cluster` | `mise run //platform/ansible:deploy:cluster` |
| `mise run ansible:deploy-cert-manager` | `mise run //platform/charts/cert-manager:apply` |
| `mise run ansible:ping` | `mise run //platform/ansible:ping` |
| `mise run deploy:full` | `mise run deploy` |

## Critical Implementation Details

### K3s Auto-Deploy Manifests
The Hetzner CCM and CSI are deployed via K3s auto-deploy manifests (templated before K3s starts):
- **CCM**: `/var/lib/rancher/k3s/server/manifests/hcloud-ccm.yaml`
- **CSI**: `/var/lib/rancher/k3s/server/manifests/hcloud-csi.yaml`

Templates are in `platform/ansible/playbooks/templates/`.

### Deployment Flow
```
infrastructure/tofu:apply
    -> Creates Hetzner servers, network, firewall, load balancer
    -> cloud-init provisions base system

platform/ansible:deploy
    -> Templates CCM/CSI manifests BEFORE K3s starts
    -> Installs K3s on all nodes (init + join)
    -> K3s auto-applies CCM/CSI manifests
    -> Deploys 1Password Connect

platform/charts/cert-manager:apply
    -> Deploys cert-manager via HelmChart CRD
    -> Configures ClusterIssuers for Let's Encrypt
    -> Creates wildcard certificate

platform/charts/step-ca:apply
    -> Deploys step-ca for internal PKI

services/*:deploy
    -> Deploys individual services
```

### Secrets Scoping
Secrets are organized by layer:
- **Root**: Shared secrets (HCLOUD_TOKEN, Cloudflare config, domain)
- **platform/ansible**: K3S_TOKEN, K3S_ETCD_SECRET, 1Password Connect
- **platform/charts/cert-manager**: CERT_MANAGER_EMAIL, CLOUDFLARE_API_TOKEN
- **services/identity**: Authentik secrets, SMTP config

### Cloud-Init Provisioning Architecture
The bootstrap process uses a modular script architecture in `/infrastructure/tofu/files/provision.d/`:
- Scripts are executed in sorted order (01, 02, 03... 30)
- Changes to cloud-init only apply to newly created servers
- Use `mise run //infrastructure/tofu:replace-nodes` to recreate all nodes

### State Isolation
- All OpenTofu files are in `/infrastructure/tofu/`
- Ansible shared inventory in `/platform/ansible/inventory/`
- Services use symlinks to shared inventory

### Security Constraints
- Admin access restricted to `73.97.54.81/32`
- HTTP/HTTPS ports (80/443) only accessible from admin IP and private network
- SSH hardened with password authentication disabled

### Firewall Architecture
**Two-layer security model**:
1. **Hetzner Cloud Firewall**: External traffic filtering
2. **Per-node firewalld**: Host-level protection (via cloud-init)

### Ansible Inventory
- **Dynamic Inventory**: Uses `hetzner.hcloud` collection
- **Server Discovery**: Filters by labels (`project=k3s-service-cluster`, `role=k3s-node`)
- **Fact Caching**: 1 hour in `/tmp/ansible_facts`
- **Service Symlinks**: Services link to `platform/ansible/inventory/`

### K3s etcd Encryption
The cluster implements encryption-at-rest for Kubernetes secrets in etcd using AES-CBC encryption:
- **Encryption Key**: Managed via `K3S_ETCD_SECRET` environment variable in 1Password
- **Configuration**: Template at `platform/ansible/roles/k3s_server/templates/etcd-encryption-config.yml.j2`
- **K3s Integration**: Applied via `--kube-apiserver-arg=encryption-provider-config` flag

## Tool Requirements

Always run `mise install` before working. The project uses:
- OpenTofu (latest)
- pre-commit (3.8.0)
- 1Password CLI (for secret management)
- kubeconform (K8s manifest validation)
- kube-linter (K8s security scanning)

## Validation Commands

After any changes, run:
1. `mise run check` - runs all validators across all layers
2. `mise run //infrastructure/tofu:plan` - verify infrastructure changes
3. `mise run //platform/ansible:ping` - verify Ansible connectivity

## Pre-commit Hooks

The project uses pre-commit for code quality:
- **Standard checks**: trailing-whitespace, end-of-file-fixer, check-yaml, check-added-large-files
- **Terraform/OpenTofu**: terraform_fmt, terraform_validate, terraform_tflint
- **YAML linting**: yamllint with custom configuration (.yamllint.yaml)

Install hooks with `pre-commit install`

## Service Scaffolding Checklist

When scaffolding a new service under `services/<name>/`, the Ansible inventory and config must exactly match the established pattern. Missing any of these causes deploy failures:

### Inventory symlink depth
The inventory symlink at `services/<name>/ansible/inventory/hcloud.yml` must resolve to `platform/ansible/inventory/hcloud.yml`. Count levels from the inventory file to the platform root:
- `services/<name>/ansible/inventory/` → `platform/` = **4 levels up**: `../../../../platform/ansible/inventory/hcloud.yml`
- A 3-level depth (`../../../`) resolves to `services/platform/...` which doesn't exist.
- Verify with: `readlink services/<name>/ansible/inventory/hcloud.yml`

### ansible.cfg must include `roles_path`
Without `roles_path = ./roles`, Ansible can't find the service's role even if the role directory exists. Every service ansible.cfg must have this line.

### ansible/mise.toml must include `[env]` with `ANSIBLE_CONFIG`
Without this, `ansible-lint` and `ansible-playbook` use the wrong config file (typically the platform-level one). Add:
```toml
[env]
ANSIBLE_CONFIG = "{{ config_root }}/ansible.cfg"
```

### ansible/mise.toml must include `init` task deploy dependency
Every deploy task should run `mise run init` first to install Ansible galaxy collections:
```toml
[tasks.init]
description = "Install Ansible collection dependencies"
run = "ansible-galaxy collection install -r requirements.yml"

[tasks.deploy]
description = "Deploy via Ansible"
run = "mise run init && op run -- ansible-playbook playbooks/deploy.yml"
```

### ansible/requirements.yml must include both collections
Required for inventory resolution:
```yaml
collections:
  - kubernetes.core
  - hetzner.hcloud
```

### New service wiring
1. Add `mise run //services/<name>/ansible:lint` to the root `[tasks.check]` chain
2. Add a deploy task to the root `[tasks.deploy]` chain (after Redis, after any prerequisites)
3. Create `services/<name>/mise.toml` with `deploy` and `check` tasks
4. Create `services/<name>/ansible/mise.toml` with `init`, `deploy`, and `lint` tasks

### Quick verification
```bash
# Verify inventory symlink
readlink services/<name>/ansible/inventory/hcloud.yml

# Verify roles_path in ansible.cfg
grep roles_path services/<name>/ansible/ansible.cfg

# Run lint before first deploy
mise run //services/<name>/ansible:lint
```
