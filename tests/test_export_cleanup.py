"""Tests for bounded delete-only export-attempt cleanup."""

from uuid import UUID

import pytest

from attune.hosted.customer_export_writer import ObjectNotFound
from attune.hosted.export_cleanup import ExportCleanupCandidate, run_export_cleanup


def _candidate(index):
    return ExportCleanupCandidate(
        UUID(int=1), UUID(int=100 + index), UUID(int=200 + index), UUID(int=300 + index)
    )


class Repository:
    def __init__(self, batches):
        self.batches = list(batches)
        self.completed = []

    def claim(self, *, cleanup_run_id, batch_size):
        return tuple(self.batches.pop(0)) if self.batches else ()

    def complete(self, candidate, *, cleanup_run_id):
        self.completed.append(candidate)
        return True


class Objects:
    def __init__(self, *, missing=(), error=None):
        self.missing = set(missing)
        self.error = error
        self.deleted = []

    def delete(self, name):
        self.deleted.append(name)
        if self.error:
            raise self.error
        if name in self.missing:
            raise ObjectNotFound()


def test_cleanup_deletes_known_names_and_treats_absence_as_success():
    candidates = [_candidate(1), _candidate(2)]
    missing = {f"objects/{candidates[1].object_id}.bin"}
    repository = Repository([candidates])
    objects = Objects(missing=missing)
    result = run_export_cleanup(repository, objects, batch_size=10)
    assert result == {"objects_deleted": 2, "batches": 1, "backlog_possible": False}
    assert repository.completed == candidates
    assert all(name.startswith("objects/") and name.endswith(".bin") for name in objects.deleted)


def test_storage_failure_leaves_database_claim_uncompleted():
    repository = Repository([[_candidate(1)]])
    with pytest.raises(RuntimeError, match="storage unavailable"):
        run_export_cleanup(repository, Objects(error=RuntimeError("storage unavailable")))
    assert repository.completed == []


def test_cleanup_is_bounded_and_reports_possible_backlog():
    repository = Repository([[_candidate(1)], [_candidate(2)]])
    result = run_export_cleanup(repository, Objects(), batch_size=1, max_batches=2)
    assert result == {"objects_deleted": 2, "batches": 2, "backlog_possible": True}


@pytest.mark.parametrize("batch,max_batches", [(0, 1), (101, 1), (1, 0), (1, 11), (True, 1)])
def test_cleanup_rejects_unbounded_configuration(batch, max_batches):
    with pytest.raises(ValueError):
        run_export_cleanup(Repository([]), Objects(), batch_size=batch, max_batches=max_batches)
