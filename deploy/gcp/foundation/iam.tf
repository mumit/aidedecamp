locals {
  workload_accounts = {
    control_plane   = "ctl"
    oauth_callback  = "oauth-cb"
    oauth_exchange  = "oauth-xchg"
    dispatch_broker = "task-broker"
    ingress         = "ingress"
    worker          = "worker"
    secret_broker   = "secrets"
    task_dispatch   = "dispatch"
    audit_writer    = "audit"
  }
}

resource "google_service_account" "workload" {
  for_each     = local.workload_accounts
  account_id   = "${local.prefix}-${each.value}"
  display_name = "Attune ${var.environment} ${replace(each.key, "_", " ")}"
  description  = "Dedicated identity for the Attune ${each.key} trust boundary"
}

resource "google_project_iam_member" "runtime_logging" {
  for_each = {
    for name, account in google_service_account.workload : name => account
    if !contains(["oauth_callback", "oauth_exchange"], name)
  }
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${each.value.email}"
}

resource "google_project_iam_member" "runtime_metrics" {
  for_each = google_service_account.workload
  project  = var.project_id
  role     = "roles/monitoring.metricWriter"
  member   = "serviceAccount:${each.value.email}"
}

resource "google_project_iam_member" "database_client" {
  for_each = toset([
    "audit_writer",
    "control_plane",
    "dispatch_broker",
    "oauth_exchange",
    "secret_broker",
    "worker",
  ])
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.workload[each.value].email}"
}

resource "google_project_iam_member" "database_instance_user" {
  for_each = toset([
    "audit_writer",
    "control_plane",
    "dispatch_broker",
    "oauth_exchange",
    "secret_broker",
    "worker",
  ])
  project = var.project_id
  role    = "roles/cloudsql.instanceUser"
  member  = "serviceAccount:${google_service_account.workload[each.value].email}"
}

resource "google_sql_user" "workload" {
  for_each = toset([
    "audit_writer",
    "control_plane",
    "dispatch_broker",
    "oauth_exchange",
    "secret_broker",
    "worker",
  ])
  name = trimsuffix(
    google_service_account.workload[each.value].email,
    ".gserviceaccount.com",
  )
  instance = google_sql_database_instance.postgres.name
  type     = "CLOUD_IAM_SERVICE_ACCOUNT"
}

resource "google_cloud_tasks_queue_iam_member" "ingress_enqueuer" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_tasks_queue.ingress.name
  role     = "roles/cloudtasks.enqueuer"
  member   = "serviceAccount:${google_service_account.workload["dispatch_broker"].email}"
}

resource "google_cloud_tasks_queue_iam_member" "jobs_enqueuer" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_tasks_queue.jobs.name
  role     = "roles/cloudtasks.enqueuer"
  member   = "serviceAccount:${google_service_account.workload["dispatch_broker"].email}"
}

resource "google_service_account_iam_member" "task_identity_user" {
  service_account_id = google_service_account.workload["task_dispatch"].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.workload["dispatch_broker"].email}"
}

resource "google_project_service_identity" "cloud_tasks" {
  provider = google-beta
  project  = var.project_id
  service  = "cloudtasks.googleapis.com"

  depends_on = [google_project_service.required]
}

resource "google_service_account_iam_member" "cloud_tasks_token_creator" {
  service_account_id = google_service_account.workload["task_dispatch"].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_project_service_identity.cloud_tasks.email}"
}

resource "google_secret_manager_secret_iam_member" "broker_access" {
  for_each  = google_secret_manager_secret.platform
  project   = var.project_id
  secret_id = each.value.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.workload["secret_broker"].email}"
}

resource "google_kms_crypto_key_iam_member" "broker_connector_crypto" {
  crypto_key_id = google_kms_crypto_key.connector_credentials.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.workload["secret_broker"].email}"
}

resource "google_storage_bucket_iam_member" "audit_create" {
  bucket = google_storage_bucket.audit.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.workload["audit_writer"].email}"
}
