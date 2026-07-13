# Test cluster — temporary K3s cluster for full backup-restore drills.
# Runs 1 node by default (cloud instance limits) sized to cover production's
# cumulative resources; topology otherwise mirrors prod (control-plane LB,
# private network, firewall, prod cloud-init + Ansible bootstrap).
#
# Mirrors infrastructure/tofu (control-plane LB + private network +
# firewall + prod cloud-init), with:
#   - distinct names/labels (project=k3s-service-cluster-test) so the prod
#     Ansible dynamic inventory and hcloud_facts lookups NEVER match these
#     resources — and vice versa
#   - a separate private network (10.0.0.0/16 vs prod 192.168.0.0/16) with
#     no peering: no IP-level path between test and prod in either direction
#   - prod's own cloud-init template and provision.d scripts, reused via
#     relative path, so node provisioning is byte-identical to prod
#
# Provision:  tofu apply
# Bootstrap:  same Ansible playbooks as prod, with the test inventory —
#             see docs/BACKUP-TESTING-FULL-CLUSTER-RESTORE.md Phase 2
# Teardown:   tofu destroy

provider "hcloud" {
  token = var.hcloud_token
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

locals {
  # Reuse production's node provisioning verbatim
  prod_module = "${path.module}/../../../infrastructure/tofu"

  labels = {
    project     = "k3s-service-cluster-test"
    environment = "test"
    purpose     = "backup-restore-test"
  }
}

data "hcloud_ssh_key" "k3s_ssh_key" {
  name = var.ssh_key_name
}

# Private Network — separate range from prod (192.168.0.0/16); Hetzner
# private networks are isolated from each other, so this alone guarantees
# no node-to-node path between test and prod.
resource "hcloud_network" "test" {
  name     = "k3s-network-test"
  ip_range = "10.0.0.0/16"
  labels   = merge(local.labels, { role = "k3s-network" })
}

resource "hcloud_network_subnet" "test" {
  type         = "cloud"
  network_id   = hcloud_network.test.id
  network_zone = var.network_zone
  ip_range     = "10.0.1.0/24"
}

# Control-plane Load Balancer — mirrors prod (lb11, private IP .10,
# label-selector targets, same four services incl. PROXY protocol on 80/443).
# NOTE: Hetzner LBs cannot have Cloud Firewalls attached; like prod, every
# LB service below is publicly reachable. See the runbook's exposure note.
resource "hcloud_load_balancer" "test" {
  name               = "k3s-control-plane-lb-test"
  load_balancer_type = "lb11"
  location           = var.location
  labels             = merge(local.labels, { role = "k3s-control-plane" })
}

resource "hcloud_load_balancer_network" "test" {
  load_balancer_id = hcloud_load_balancer.test.id
  network_id       = hcloud_network.test.id
  ip               = "10.0.1.10"
  depends_on       = [hcloud_network_subnet.test]
}

resource "hcloud_load_balancer_target" "test" {
  type             = "label_selector"
  load_balancer_id = hcloud_load_balancer.test.id
  label_selector   = "project=k3s-service-cluster-test,role=k3s-node"
  use_private_ip   = true
  depends_on       = [hcloud_load_balancer_network.test]
}

resource "hcloud_load_balancer_service" "k3s_api" {
  load_balancer_id = hcloud_load_balancer.test.id
  protocol         = "tcp"
  listen_port      = 6443
  destination_port = 6443
  health_check {
    protocol = "tcp"
    port     = 6443
    interval = 10
    timeout  = 5
    retries  = 3
  }
  depends_on = [hcloud_load_balancer_target.test]
}

resource "hcloud_load_balancer_service" "http" {
  load_balancer_id = hcloud_load_balancer.test.id
  protocol         = "tcp"
  listen_port      = 80
  destination_port = 8080
  proxyprotocol    = true
  health_check {
    protocol = "tcp"
    port     = 8080
    interval = 10
    timeout  = 5
    retries  = 3
  }
  depends_on = [hcloud_load_balancer_target.test]
}

resource "hcloud_load_balancer_service" "https" {
  load_balancer_id = hcloud_load_balancer.test.id
  protocol         = "tcp"
  listen_port      = 443
  destination_port = 8443
  proxyprotocol    = true
  health_check {
    protocol = "tcp"
    port     = 8443
    interval = 10
    timeout  = 5
    retries  = 3
  }
  depends_on = [hcloud_load_balancer_target.test]
}

resource "hcloud_load_balancer_service" "gitea_ssh" {
  load_balancer_id = hcloud_load_balancer.test.id
  protocol         = "tcp"
  listen_port      = 2222
  destination_port = 2222
  health_check {
    protocol = "tcp"
    port     = 2222
    interval = 10
    timeout  = 5
    retries  = 3
  }
  depends_on = [hcloud_load_balancer_target.test]
}

# Cloud Firewall — mirrors prod rule-for-rule, with the internal CIDR
# swapped to this cluster's own network. (Hetzner firewalls filter public
# interfaces only; private-network traffic between the nodes is unaffected.)
resource "hcloud_firewall" "test" {
  name = "k3s-firewall-test"

  rule {
    direction  = "in"
    port       = "22"
    protocol   = "tcp"
    source_ips = [var.allowed_admin_cidr]
  }

  rule {
    direction  = "in"
    port       = "6443"
    protocol   = "tcp"
    source_ips = [var.allowed_admin_cidr]
  }

  rule {
    direction  = "in"
    port       = "80"
    protocol   = "tcp"
    source_ips = [var.allowed_admin_cidr, "10.0.0.0/16"]
  }

  rule {
    direction  = "in"
    port       = "443"
    protocol   = "tcp"
    source_ips = [var.allowed_admin_cidr, "10.0.0.0/16"]
  }

  rule {
    direction  = "in"
    port       = "2222"
    protocol   = "tcp"
    source_ips = [var.allowed_admin_cidr]
  }

  rule {
    direction  = "in"
    port       = "any"
    protocol   = "tcp"
    source_ips = ["10.0.0.0/16"]
  }

  rule {
    direction  = "in"
    port       = "any"
    protocol   = "udp"
    source_ips = ["10.0.0.0/16"]
  }

  rule {
    direction  = "in"
    protocol   = "icmp"
    source_ips = ["10.0.0.0/16"]
  }
}

# K3s Nodes — same image, layout, and cloud-init as production. Node count
# and per-node size come from var.server_types: default is ONE node covering
# prod's cumulative resources (see variables.tf) due to instance limits.
# Topology still mirrors prod where it matters for the drill: control-plane
# LB (which hcloud_facts and the kubeconfig endpoint require), private
# network, firewall, and the prod Ansible bootstrap (the join play simply
# matches no hosts). Single-node etcd has no fault tolerance — fine for an
# ephemeral drill; it does NOT exercise prod's node-failure behavior.
# Names are distinct (k3s-test-node-*) both because hcloud requires unique
# names and so inventory host patterns can never cross environments.
resource "hcloud_server" "test_nodes" {
  count       = length(var.server_types)
  name        = "k3s-test-node-${format("%02d", count.index + 1)}"
  image       = "debian-12"
  server_type = var.server_types[count.index]
  location    = var.location
  ssh_keys    = [data.hcloud_ssh_key.k3s_ssh_key.id]

  firewall_ids = [hcloud_firewall.test.id]

  labels = merge(local.labels, {
    role       = "k3s-node"
    node_index = tostring(count.index)
  })

  # Production's cloud-init, verbatim (CIS sysctls, hardening packages,
  # provision.d scripts). path_module points at the prod module so the
  # template's fileset() picks up the same scripts prod nodes run.
  user_data = templatefile("${local.prod_module}/cloud-init.yaml", {
    path_module = local.prod_module
  })

  network {
    network_id = hcloud_network.test.id
    ip         = "10.0.1.${count.index + 2}"
  }

  depends_on = [hcloud_network_subnet.test]
}

# Wildcard DNS for the test domain — points to the test LB.
# The zone for salishseawolf.bid must exist in Cloudflare.
# SAFETY: the zone is resolved by NAME from var.test_domain, deliberately
# NOT from TF_VAR_cloudflare_zone_id — the root mise.toml exports that from
# the production (.com) credentials for infrastructure/tofu, and using it
# here would create a wildcard record in the PRODUCTION zone pointing at
# the test LB. The API token's zone scope must include salishseawolf.bid.
data "cloudflare_zone" "test" {
  name = var.test_domain
}

resource "cloudflare_record" "wildcard" {
  zone_id = data.cloudflare_zone.test.id
  name    = "*"
  content = hcloud_load_balancer.test.ipv4
  type    = "A"
  ttl     = 120
}

output "test_lb_ip" {
  value       = hcloud_load_balancer.test.ipv4
  description = "Public IP of the test control-plane LB — *.salishseawolf.bid points here"
}

output "test_node_ips" {
  value       = hcloud_server.test_nodes[*].ipv4_address
  description = "Public IPs of the test nodes (SSH)"
}
