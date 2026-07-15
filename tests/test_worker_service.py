from __future__ import annotations

from types import SimpleNamespace

from attune.hosted.worker_service import create_app


class Dispatcher:
    def __init__(self, *, status=204, error=None):
        self.status = status
        self.error = error
        self.calls = []

    def dispatch(self, **request):
        self.calls.append(request)
        if self.error:
            raise self.error
        return SimpleNamespace(status_code=self.status)


def test_worker_passes_raw_authenticated_envelope_unchanged():
    dispatcher = Dispatcher()
    app = create_app(dispatcher).test_client()
    body = b'{"version":1}'
    response = app.post(
        "/v1/tasks/dispatch",
        data=body,
        content_type="application/json",
        headers={"Authorization": "Bearer token"},
    )
    assert response.status_code == 204
    assert dispatcher.calls == [
        {"authorization": "Bearer token", "raw_body": body}
    ]


def test_worker_rejects_non_json_and_returns_generic_failure():
    dispatcher = Dispatcher(error=RuntimeError("sensitive detail"))
    app = create_app(dispatcher).test_client()
    assert app.get("/healthz").get_json() == {"status": "ok"}
    assert app.post(
        "/v1/tasks/dispatch", data=b"{}", content_type="text/plain"
    ).status_code == 400
    response = app.post(
        "/v1/tasks/dispatch", data=b"{}", content_type="application/json"
    )
    assert response.status_code == 503
    assert b"sensitive detail" not in response.data
