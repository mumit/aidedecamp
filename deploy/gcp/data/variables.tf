variable "state_bucket" {
  description = "Private GCS bucket containing the foundation remote state."
  type        = string
}

variable "foundation_state_prefix" {
  description = "GCS prefix of the foundation Terraform state."
  type        = string
  default     = "foundation"
}

variable "migrator_image" {
  description = "Artifact Registry migrator image pinned by sha256 digest."
  type        = string

  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.migrator_image))
    error_message = "migrator_image must be an immutable @sha256 Artifact Registry reference."
  }
}

variable "initial_tenant_slug" {
  description = "Non-sensitive slug for the single operator-provisioned initial tenant."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,62}$", var.initial_tenant_slug))
    error_message = "initial_tenant_slug must be a lowercase DNS-style slug."
  }
}

variable "labels" {
  description = "Additional non-sensitive resource labels."
  type        = map(string)
  default     = {}
}
