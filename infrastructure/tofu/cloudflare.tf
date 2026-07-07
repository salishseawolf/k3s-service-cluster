# Cloudflare DNS Records for K3s Cluster
# Both root and wildcard point to the control plane LB which handles
# K3s API (6443) and web traffic via Traefik (80/443)

resource "cloudflare_record" "root" {
  zone_id = var.cloudflare_zone_id
  name    = "@"
  content = hcloud_load_balancer.k3s_control_plane.ipv4
  type    = "A"
  ttl     = 300
  proxied = false

  comment = "Managed by OpenTofu - K3s Service Cluster"
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
