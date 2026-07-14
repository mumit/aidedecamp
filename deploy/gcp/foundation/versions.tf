terraform {
  required_version = ">= 1.8.0, < 2.0.0"

  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "7.34.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "7.34.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}
