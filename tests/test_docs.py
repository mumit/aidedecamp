"""Documentation consistency tests."""

from __future__ import annotations

import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_every_example_environment_variable_is_documented():
    example = (ROOT / ".env.example").read_text()
    reference = (ROOT / "docs" / "configuration.md").read_text()

    example_keys = set(
        re.findall(r"^(?:# )?([A-Z][A-Z0-9_]+)=", example, flags=re.MULTILINE)
    )
    documented_keys = set(
        re.findall(r"^\| `([A-Z][A-Z0-9_]+)` \|", reference, flags=re.MULTILINE)
    )

    assert documented_keys == example_keys


def test_quickstart_uses_guided_local_setup():
    readme = (ROOT / "README.md").read_text()
    quickstart = readme.split("## Quick start", 1)[1].split("## Development", 1)[0]

    assert "attune init --target local" in quickstart
    assert "docker compose" not in quickstart
    assert "attune doctor" not in quickstart


def test_qdrant_compose_images_are_pinned_and_loopback_bound():
    compose = (ROOT / "deploy" / "compose.yml").read_text()
    local = (ROOT / "src" / "attune" / "resources" / "local-compose.yml").read_text()

    assert "qdrant/qdrant:latest" not in compose + local
    assert "qdrant/qdrant:v1.18.2" in compose
    assert "qdrant/qdrant:v1.18.2" in local
    assert '"127.0.0.1:6333:6333"' in compose
    assert '"127.0.0.1:6333:6333"' in local


def test_slack_owner_destination_reuses_allowlisted_user_id():
    guide = (ROOT / "docs" / "getting-started.md").read_text()

    assert "ATTUNE_SLACK_CHANNEL=U0123456789" in guide
    assert "conversations_open" not in guide


def test_gcp_foundation_preserves_hosted_security_boundaries():
    root = ROOT / "deploy" / "gcp" / "foundation"
    terraform = "\n".join(path.read_text() for path in sorted(root.glob("*.tf")))

    assert 'version = "7.34.0"' in terraform
    assert 'ipv4_enabled    = false' in terraform
    assert 'cloudsql.iam_authentication' in terraform
    assert 'edition                     = "ENTERPRISE"' in terraform
    assert '".gserviceaccount.com"' in terraform
    assert 'deletion_protection = true' in terraform
    assert 'public_access_prevention    = "enforced"' in terraform
    assert 'prevent_destroy = true' in terraform
    assert 'serviceAccount:gmail-api-push@system.gserviceaccount.com' in terraform
    assert 'roles/secretmanager.secretAccessor' in terraform
    assert 'name            = "connector-credentials"' in terraform
    assert 'roles/cloudkms.cryptoKeyEncrypterDecrypter' in terraform
    assert 'roles/secretmanager.secretVersionAdder' not in terraform
    assert 'roles/secretmanager.admin' not in terraform
    assert 'roles/editor' not in terraform
    assert 'roles/owner' not in terraform
    assert "secret_manager_secret_version" not in terraform
    assert "google_cloud_run_v2_service" not in terraform


def test_gcp_foundation_documents_no_customer_data_gate():
    foundation = (ROOT / "deploy" / "gcp" / "foundation" / "README.md").read_text()
    architecture = (ROOT / "docs" / "hosted-gcp.md").read_text()
    normalized_foundation = " ".join(foundation.split())
    normalized_architecture = " ".join(architecture.split())

    assert "does not admit customer data" in normalized_foundation
    assert "gmail-api-push@system.gserviceaccount.com" in foundation
    assert "constraints/iam.allowedPolicyMemberDomains" in foundation
    assert "add-iam-policy-binding" in foundation
    assert "restore_domain_policy" in foundation
    assert "terraform plan -detailed-exitcode" in foundation
    assert "Repeat this procedure only for a new topic/project" in normalized_foundation
    assert "making the topic public" in normalized_foundation
    assert "No secret value may enter Terraform state" in normalized_architecture
    assert "Production is blocked" in normalized_architecture
