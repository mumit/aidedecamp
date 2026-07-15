terraform {
  required_version = ">= 1.8.0, < 2.0.0"

  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "7.34.0"
    }
  }
}

provider "google" {
  project = local.foundation.project_id
  region  = local.foundation.region
}
