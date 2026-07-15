from __future__ import annotations

from types import SimpleNamespace
from uuid import UUID

import pytest

from attune.hosted.tenant import TenantContext
from attune.hosted.worker_audit import WorkerAudit, _digest

TENANT = UUID("10000000-0000-4000-8000-000000000701")
AUDIT_INTENT = UUID("10000000-0000-4000-8000-000000000702")
JOB = "10000000-0000-4000-8000-000000000703"


class Producer:
    def __init__(self):
        self.calls = []

    def request(self, context, **event):
        self.calls.append((context, event))
        return SimpleNamespace(id=AUDIT_INTENT)


class Writer:
    def __init__(self, result=True):
        self.result = result
        self.calls = []

    def write(self, intent_id):
        self.calls.append(intent_id)
        return self.result


def test_worker_audit_is_tenant_bound_and_content_free():
    producer, writer = Producer(), Writer()
    audit = WorkerAudit(producer, writer)
    audit.record(
        TenantContext(TENANT),
        action="worker.job.execute",
        outcome="allowed",
        job_id=JOB,
        caller_subject="task-delivery-subject",
    )
    assert writer.calls == [AUDIT_INTENT]
    assert producer.calls == [
        (
            TenantContext(TENANT),
            {
                "idempotency_key": _digest(
                    f"attune-worker-audit-v1:{JOB}:worker.job.execute:allowed"
                ),
                "actor_type": "workload",
                "actor_ref_hash": _digest(
                    "attune-task-delivery-subject-v1:task-delivery-subject"
                ),
                "action": "worker.job.execute",
                "outcome": "allowed",
                "target_type": "job",
                "target_ref_hash": _digest(f"attune-job-v1:{JOB}"),
            },
        )
    ]


def test_worker_audit_failure_is_not_treated_as_success():
    with pytest.raises(RuntimeError):
        WorkerAudit(Producer(), Writer(False)).record(
            TenantContext(TENANT),
            action="worker.job.claimed",
            outcome="allowed",
            job_id=JOB,
            caller_subject="subject",
        )
