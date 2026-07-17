output "foundation" {
  description = "Non-secret identifiers consumed by later runtime modules."
  value = {
    project_id                  = var.project_id
    region                      = var.region
    environment                 = var.environment
    network_id                  = google_compute_network.private.id
    subnetwork_id               = google_compute_subnetwork.application.id
    broker_egress_subnetwork_id = google_compute_subnetwork.broker_egress.id
    database_instance           = google_sql_database_instance.postgres.connection_name
    database_name               = google_sql_database.attune.name
    ingress_queue               = google_cloud_tasks_queue.ingress.id
    jobs_queue                  = google_cloud_tasks_queue.jobs.id
    provider_events_topic       = google_pubsub_topic.provider_events.id
    artifact_repository_id      = google_artifact_registry_repository.containers.id
    audit_bucket                = google_storage_bucket.audit.name
    connector_kms_key           = google_kms_crypto_key.connector_credentials.id
    customer_export_bucket      = google_storage_bucket.customer_export.name
    customer_export_kms_key     = google_kms_crypto_key.customer_export.id
    workload_identities = {
      for name, account in google_service_account.workload : name => account.email
    }
    platform_secret_ids = {
      for name, secret in google_secret_manager_secret.platform : name => secret.id
    }
  }
}
