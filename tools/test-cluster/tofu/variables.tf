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

variable "server_types" {
  description = <<-EOT
    Per-node Hetzner server types; node count = length of this list.
    Default is a single node sized to cover production's CUMULATIVE
    resources (3x cx23 = 6 vCPU / 12 GB): cx43 (8 vCPU / 16 GB) is the
    smallest type that isn't under that total (no 6/12 type exists).
    cx33 (4/8) undershoots and risks OOM with the full workload restored.
    For a full topology mirror use ["cx23", "cx23", "cx23"].
  EOT
  type        = list(string)
  default     = ["cx43"]
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token with DNS edit access for salishseawolf.bid"
  type        = string
  sensitive   = true
}

variable "test_domain" {
  description = "Test domain (registered, separate from production). The Cloudflare zone is looked up BY NAME from this — never by zone ID — so a stale/prod zone_id in the environment can never route this record into the production zone."
  type        = string
  default     = "salishseawolf.bid"
}
