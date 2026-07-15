output "migration_job" {
  description = "Operator-executed migration job identifiers."
  value = {
    project         = local.foundation.project_id
    region          = local.foundation.region
    name            = google_cloud_run_v2_job.migrate.name
    service_account = google_service_account.migrator.email
    image           = var.migrator_image
  }
}
