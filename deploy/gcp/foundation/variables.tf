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

variable "export_bucket_policy_admin_members" {
  description = "Reviewed deployment principals that may manage the export bucket IAM policy but not objects."
  type        = set(string)

  validation {
    condition = (
      length(var.export_bucket_policy_admin_members) >= 1 &&
      alltrue([
        for member in var.export_bucket_policy_admin_members :
        can(regex("^(user|serviceAccount):[^[:space:]]+@[^[:space:]]+$", member))
      ])
    )
    error_message = "export_bucket_policy_admin_members requires at least one user: or serviceAccount: principal."
  }
}

variable "jobs_worker_target_host" {
  description = "Cloud Run worker hostname for the jobs queue override; null keeps dispatch disabled."
  type        = string
  default     = null

  validation {
    condition = (
      var.jobs_worker_target_host == null ||
      can(regex("^[a-z0-9-]+(?:\\.[a-z0-9-]+)*\\.run\\.app$", var.jobs_worker_target_host))
    )
    error_message = "jobs_worker_target_host must be a Cloud Run hostname without scheme or path."
  }
}

variable "jobs_worker_oidc_audience" {
  description = "Exact custom OIDC audience for the jobs worker; null keeps dispatch disabled."
  type        = string
  default     = null

  validation {
    condition = (
      var.jobs_worker_oidc_audience == null ||
      can(regex("^https://[a-z0-9-]+\\.attune\\.internal$", var.jobs_worker_oidc_audience))
    )
    error_message = "jobs_worker_oidc_audience must be an Attune internal HTTPS audience."
  }
}

variable "labels" {
  description = "Additional non-sensitive resource labels."
  type        = map(string)
  default     = {}
}
