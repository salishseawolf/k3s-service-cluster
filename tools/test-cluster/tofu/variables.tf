variable "hcloud_token" {
  description = "Hetzner Cloud API Token"
  type        = string
  sensitive   = true
}

variable "allowed_admin_cidr" {
  description = "CIDR allowed for SSH and K8s API access. No default on purpose (mirrors prod): supply via TF_VAR_allowed_admin_cidr so a stale IP can never silently ship."
  type        = string

  validation {
    condition     = can(cidrhost(var.allowed_admin_cidr, 0))
    error_message = "allowed_admin_cidr must be a valid CIDR block, e.g. 203.0.113.7/32."
  }
}

variable "location" {
  description = "Hetzner Cloud location"
  type        = string
  default     = "hel1"
}

variable "network_zone" {
  description = "Hetzner Cloud network zone"
  type        = string
  default     = "eu-central"
}

variable "ssh_key_name" {
  description = "Name of the SSH key in Hetzner Cloud (same key as prod)"
  type        = string
}

variable "server_type" {
  description = "Hetzner server type — defaults to the same type as production nodes (infrastructure/tofu default) for a faithful mirror. (cx21 from the original draft was deprecated Sep 2024 and is not orderable.)"
  type        = string
  default     = "cx23"
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token with DNS edit access for salishseawolf.bid"
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Zone ID for salishseawolf.bid in Cloudflare"
  type        = string
}
