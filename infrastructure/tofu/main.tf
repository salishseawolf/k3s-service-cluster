# Reference existing SSH Key
data "hcloud_ssh_key" "k3s_ssh_key" {
  name = var.ssh_key_name
}

# Private Network
resource "hcloud_network" "k3s_network" {
  name     = "k3s-network"
  ip_range = "192.168.0.0/16"

  labels = {
    project     = "k3s-service-cluster"
    environment = "production"
    role        = "k3s-network"
  }
}

# Network Subnet
resource "hcloud_network_subnet" "k3s_subnet" {
  type         = "cloud"
  network_id   = hcloud_network.k3s_network.id
  network_zone = var.network_zone
  ip_range     = "192.168.1.0/24"
}

# Load Balancer for K3s Control Plane HA
resource "hcloud_load_balancer" "k3s_control_plane" {
  name               = "k3s-control-plane-lb"
  load_balancer_type = "lb11"
  location           = var.location

  labels = {
    project     = "k3s-service-cluster"
    environment = "production"
    role        = "k3s-control-plane"
  }
}

# Load Balancer Network Attachment
resource "hcloud_load_balancer_network" "k3s_control_plane" {
  load_balancer_id = hcloud_load_balancer.k3s_control_plane.id
  network_id       = hcloud_network.k3s_network.id
  ip               = "192.168.1.10"

  depends_on = [hcloud_network_subnet.k3s_subnet]
}

# Load Balancer Target - Control Plane Nodes
resource "hcloud_load_balancer_target" "k3s_control_plane" {
  type             = "label_selector"
  load_balancer_id = hcloud_load_balancer.k3s_control_plane.id
  label_selector   = "role=k3s-node"
  use_private_ip   = true

  depends_on = [hcloud_load_balancer_network.k3s_control_plane]
}

# No LB service for the K3s API (6443): Hetzner firewalls don't apply to LB
# traffic, so it would be open to the internet. Clients use api.<domain>
# (cloudflare.tf, one A record per node), where the firewall's admin-only
# 6443 rule applies. Nodes join each other over the private network.

# Load Balancer Service - HTTP (Traefik ingress on 8080)
resource "hcloud_load_balancer_service" "http" {
  load_balancer_id = hcloud_load_balancer.k3s_control_plane.id
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

  depends_on = [hcloud_load_balancer_target.k3s_control_plane]
}

# Load Balancer Service - HTTPS (Traefik ingress on 8443)
resource "hcloud_load_balancer_service" "https" {
  load_balancer_id = hcloud_load_balancer.k3s_control_plane.id
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

  depends_on = [hcloud_load_balancer_target.k3s_control_plane]
}

# Load Balancer Service - Gitea SSH (Traefik TCP on 2222)
resource "hcloud_load_balancer_service" "gitea_ssh" {
  load_balancer_id = hcloud_load_balancer.k3s_control_plane.id
  protocol         = "tcp"
  listen_port      = 2222
  destination_port = 2222
  # Pass the client IP to Traefik's ssh entrypoint so the gitea-ssh-allowlist
  # MiddlewareTCP can enforce adminSourceRanges. Apply only after Traefik
  # trusts PROXY protocol on 2222 (bootstrap traefik-config.yaml.j2).
  proxyprotocol = true

  health_check {
    protocol = "tcp"
    port     = 2222
    interval = 10
    timeout  = 5
    retries  = 3
  }

  depends_on = [hcloud_load_balancer_target.k3s_control_plane]
}

# Cloud Firewall
resource "hcloud_firewall" "k3s_firewall" {
  name = "k3s-firewall"

  rule {
    direction = "in"
    port      = "22"
    protocol  = "tcp"
    source_ips = [
      var.allowed_admin_cidr
    ]
  }

  rule {
    direction = "in"
    port      = "6443"
    protocol  = "tcp"
    source_ips = [
      var.allowed_admin_cidr
    ]
  }

  rule {
    direction = "in"
    port      = "80"
    protocol  = "tcp"
    source_ips = [
      var.allowed_admin_cidr,
      "192.168.0.0/16"
    ]
  }

  rule {
    direction = "in"
    port      = "443"
    protocol  = "tcp"
    source_ips = [
      var.allowed_admin_cidr,
      "192.168.0.0/16"
    ]
  }

  rule {
    direction = "in"
    port      = "2222"
    protocol  = "tcp"
    source_ips = [
      var.allowed_admin_cidr
    ]
  }

  rule {
    direction = "in"
    port      = "any"
    protocol  = "tcp"
    source_ips = [
      "192.168.0.0/16"
    ]
  }

  rule {
    direction = "in"
    port      = "any"
    protocol  = "udp"
    source_ips = [
      "192.168.0.0/16"
    ]
  }

  rule {
    direction = "in"
    protocol  = "icmp"
    source_ips = [
      "192.168.0.0/16"
    ]
  }
}

# K3s Nodes
resource "hcloud_server" "k3s_nodes" {
  count       = 3
  name        = "k3s-converged-node-${format("%02d", count.index + 1)}"
  image       = "debian-12"
  server_type = var.server_type
  location    = var.location
  ssh_keys    = [data.hcloud_ssh_key.k3s_ssh_key.id]

  firewall_ids = [hcloud_firewall.k3s_firewall.id]

  labels = {
    project     = "k3s-service-cluster"
    environment = "production"
    role        = "k3s-node"
    node_index  = tostring(count.index)
  }

  user_data = templatefile("${path.module}/cloud-init.yaml", {
    path_module = path.module
  })

  network {
    network_id = hcloud_network.k3s_network.id
    ip         = "192.168.1.${count.index + 2}"
  }

  depends_on = [hcloud_network_subnet.k3s_subnet]
}


# Update SSH known_hosts on local workstation when servers change
resource "null_resource" "update_known_hosts" {
  triggers = {
    server_ids = join(",", hcloud_server.k3s_nodes[*].id)
  }

  provisioner "local-exec" {
    command = <<-EOT
      for ip in ${join(" ", hcloud_server.k3s_nodes[*].ipv4_address)}; do
        # Remove old key
        ssh-keygen -R $ip 2>/dev/null || true

        # Wait for SSH to be ready (max 60 seconds)
        echo "Waiting for SSH on $ip..."
        for i in {1..12}; do
          if ssh-keyscan -H $ip 2>/dev/null | grep -q ssh; then
            ssh-keyscan -H $ip >> ~/.ssh/known_hosts 2>/dev/null
            echo "SSH key added for $ip"
            break
          fi
          sleep 5
        done
      done
    EOT
  }

  depends_on = [hcloud_server.k3s_nodes]
}
