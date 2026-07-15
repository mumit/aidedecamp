"""One-purpose operator job for the first hosted tenant identity mapping."""

from __future__ import annotations

import os
import re
import sys
from contextlib import closing

from .migrate import _cloud_sql_connection

_SUBJECT_HASH = re.compile(r"^[0-9a-f]{64}$")
_ISSUER = re.compile(r"^https://securetoken[.]google[.]com/[a-z][a-z0-9-]{4,29}$")
_SLUG = re.compile(r"^[a-z0-9][a-z0-9-]{1,62}$")
_REGION = re.compile(r"^[a-z][a-z0-9-]{1,62}$")
_SECRET_RESOURCE = re.compile(
    r"^projects/(?:[0-9]{6,20}|[a-z][a-z0-9-]{4,28}[a-z0-9])/"
    r"secrets/[a-z][a-z0-9-]{1,254}$"
)


def _required(name: str, pattern: re.Pattern[str]) -> str:
    value = os.environ.get(name, "")
    if not pattern.fullmatch(value):
        raise ValueError(f"{name} is missing or invalid")
    return value


def _subject_hash_from_secret(resource: str) -> str:
    from google.cloud import secretmanager_v1

    response = secretmanager_v1.SecretManagerServiceClient().access_secret_version(
        request={"name": f"{resource}/versions/latest"}
    )
    try:
        value = bytes(response.payload.data).decode("ascii")
    except (UnicodeDecodeError, ValueError) as error:
        raise ValueError("identity bootstrap secret is invalid") from error
    if not _SUBJECT_HASH.fullmatch(value):
        raise ValueError("identity bootstrap secret is invalid")
    return value


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if argv:
        raise ValueError("the identity provisioner accepts no runtime arguments")

    secret_resource = _required(
        "ATTUNE_IDENTITY_BOOTSTRAP_SECRET", _SECRET_RESOURCE
    )
    subject_hash = _subject_hash_from_secret(secret_resource)
    issuer = _required("ATTUNE_IDENTITY_ISSUER", _ISSUER)
    tenant_slug = _required("ATTUNE_INITIAL_TENANT_SLUG", _SLUG)
    region = _required("ATTUNE_INITIAL_TENANT_REGION", _REGION)

    owner, connection = _cloud_sql_connection()
    try:
        with closing(connection):
            try:
                with closing(connection.cursor()) as cursor:
                    cursor.execute(
                        """
                        SELECT tenant_id, principal_id, created
                          FROM attune.provision_initial_identity(
                              decode(%s, 'hex'), %s, %s, %s
                          )
                        """,
                        (subject_hash, issuer, tenant_slug, region),
                    )
                    rows = cursor.fetchall()
                if len(rows) != 1 or not isinstance(rows[0][2], bool):
                    raise RuntimeError("identity provisioning returned ambiguous state")
                connection.commit()
            except BaseException:
                connection.rollback()
                raise
        print(
            "initial identity mapping verified; "
            f"created={'true' if rows[0][2] else 'false'}"
        )
    finally:
        if owner is not None:
            owner.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
