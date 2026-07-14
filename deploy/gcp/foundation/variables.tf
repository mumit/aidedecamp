variable "project_id" {
  description = "Existing, billing-enabled GCP project dedicated to this environment."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project id."
  }
}

variable "region" {
  description = "Single region used for data and application services."
  type        = string
  default     = "northamerica-northeast1"
}

variable "environment" {
  description = "Isolation boundary. Use a separate project for every environment."
  type        = string

  validation {
    condition     = contains(["development", "staging", "production"], var.environment)
    error_message = "environment must be development, staging, or production."
  }
}

variable "sql_tier" {
  description = "Cloud SQL machine tier; production should be sized from load tests."
  type        = string
  default     = "db-custom-2-7680"
}

variable "database_version" {
  description = "Cloud SQL PostgreSQL major version."
  type        = string
  default     = "POSTGRES_16"
}

variable "backup_retention_count" {
  description = "Number of automated Cloud SQL backups to retain."
  type        = number
  default     = 14

  validation {
    condition     = var.backup_retention_count >= 7 && var.backup_retention_count <= 365
    error_message = "backup_retention_count must be between 7 and 365."
  }
}

variable "audit_retention_days" {
  description = "Minimum retention for exported security audit objects."
  type        = number
  default     = 400

  validation {
    condition     = var.audit_retention_days >= 365
    error_message = "audit_retention_days must be at least 365."
  }
}

variable "lock_audit_retention" {
  description = "Permanently lock the audit bucket retention policy. Required in production and irreversible."
  type        = bool
  default     = false
}

variable "labels" {
  description = "Additional non-sensitive resource labels."
  type        = map(string)
  default     = {}
}
