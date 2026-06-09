variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Used for resource names and tags"
  type        = string
  default     = "quran-muaalem"
}

variable "repo_url" {
  description = <<-EOT
    HTTPS clone URL of the repository.
    For a public repo:  https://github.com/quralingo/recitation_by_ayah.git
    For a private repo: https://YOUR_PAT@github.com/quralingo/recitation_by_ayah.git
  EOT
  type      = string
  sensitive = true
}

variable "ssh_public_key" {
  description = "SSH public key content for EC2 access (e.g. content of ~/.ssh/id_ed25519.pub)"
  type        = string
  sensitive   = true
}

variable "ssh_allowed_cidr" {
  description = "CIDR allowed to SSH. Restrict to your IP (e.g. 1.2.3.4/32) for security."
  type        = string
  default     = "0.0.0.0/0"
}

variable "use_spot" {
  description = <<-EOT
    true  = Spot instance (~$0.16/hr). Requires AWS quota for G-instance spot.
            New accounts: request via Service Quotas → EC2 → "All G and VT Spot Instance Requests" (need 4 vCPUs).
    false = On-demand (~$0.53/hr). Works immediately on any account.
  EOT
  type    = bool
  default = true
}

variable "spot_max_price" {
  description = <<-EOT
    Maximum hourly Spot bid for g4dn.xlarge.
    On-demand price: ~$0.526/hr. Spot typically runs at ~$0.16/hr.
    Setting max to $0.25 gives a buffer while staying far below on-demand.
  EOT
  type    = string
  default = "0.25"
}
