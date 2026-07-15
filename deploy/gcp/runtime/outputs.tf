output "audit_writer" {
  description = "Private audit-writer service identifiers."
  value = {
    project         = local.foundation.project_id
    region          = local.foundation.region
    name            = google_cloud_run_v2_service.audit_writer.name
    uri             = google_cloud_run_v2_service.audit_writer.uri
    service_account = local.foundation.workload_identities.audit_writer
    image           = var.audit_writer_image
  }
}
