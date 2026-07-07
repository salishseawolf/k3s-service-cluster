output "node_public_ips" {
  description = "Public IPv4 addresses of all K3s nodes"
  value       = hcloud_server.k3s_nodes[*].ipv4_address
}

output "node_private_ips" {
  description = "Private IPv4 addresses of all K3s nodes"
  value       = [for server in hcloud_server.k3s_nodes : tolist(server.network)[0].ip]
}

output "load_balancer_ip" {
  description = "Load Balancer IP address for K3s API (control plane endpoint)"
  value       = hcloud_load_balancer.k3s_control_plane.ipv4
}

output "load_balancer_private_ip" {
  description = "Load Balancer private IP address"
  value       = hcloud_load_balancer_network.k3s_control_plane.ip
}

output "node_names" {
  description = "Names of all K3s nodes"
  value       = hcloud_server.k3s_nodes[*].name
}

# DNS Outputs
output "domain" {
  description = "Base domain name"
  value       = var.domain
}

output "dns_records" {
  description = "DNS records created in Cloudflare"
  value = {
    root     = "${var.domain} -> ${hcloud_load_balancer.k3s_control_plane.ipv4}"
    wildcard = "*.${var.domain} -> ${hcloud_load_balancer.k3s_control_plane.ipv4}"
  }
}