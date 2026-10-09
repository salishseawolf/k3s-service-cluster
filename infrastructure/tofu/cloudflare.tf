# Cloudflare DNS Records for K3s Cluster
# Root and wildcard point to the LB (web traffic via Traefik, 80/443, and
# Gitea SSH, 2222). The K3s API has its own per-node name (api).

resource "cloudflare_record" "root" {
  zone_id = var.cloudflare_zone_id
  name    = "@"
  content = hcloud_load_balancer.k3s_control_plane.ipv4
  type    = "A"
  ttl     = 300
  proxied = false

  comment = "Managed by OpenTofu - K3s Service Cluster"
}

# K3s API, straight to the nodes: one A record per node, so the Hetzner
# firewall (6443 admin-only) applies. Hetzner firewalls don't cover LB
# traffic. Clients fail over across the records on connect. This specific
# name overrides the wildcard below.
resource "cloudflare_record" "api" {
  count   = length(hcloud_server.k3s_nodes)
  zone_id = var.cloudflare_zone_id
  name    = "api"
  content = hcloud_server.k3s_nodes[count.index].ipv4_address
  type    = "A"
  ttl     = 60
  proxied = false

  comment = "Managed by OpenTofu - K3s Service Cluster (K3s API, ${hcloud_server.k3s_nodes[count.index].name})"
}

resource "cloudflare_record" "wildcard" {
  zone_id = var.cloudflare_zone_id
  name    = "*"
  content = hcloud_load_balancer.k3s_control_plane.ipv4
  type    = "A"
  ttl     = 300
  proxied = false

  comment = "Managed by OpenTofu - K3s Service Cluster"
}
