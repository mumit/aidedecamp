FROM node:24-alpine@sha256:a0b9bf06e4e6193cf7a0f58816cc935ff8c2a908f81e6f1a95432d679c54fbfd AS identity-assets

WORKDIR /workspace

COPY web/hosted-identity/package.json web/hosted-identity/package-lock.json web/hosted-identity/
RUN npm ci --prefix web/hosted-identity --ignore-scripts
COPY web/hosted-identity/src web/hosted-identity/src
RUN mkdir -p src/attune/hosted/static \
    && npm --prefix web/hosted-identity run build

FROM python:3.12-slim@sha256:c3d81d25b3154142b0b42eb1e61300024426268edeb5b5a26dd7ddf64d9daf28

WORKDIR /app

COPY pyproject.toml README.md LICENSE ./
COPY src src
COPY --from=identity-assets /workspace/src/attune/hosted/static/identity.js src/attune/hosted/static/identity.js

RUN pip install --no-cache-dir --no-compile ".[hosted-service]" \
    && groupadd --system --gid 65532 attune \
    && useradd --system --uid 65532 --gid attune --home-dir /nonexistent attune

USER 65532:65532

ENV PORT=8080

CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--threads", "4", "--timeout", "30", "attune.hosted.control_plane_app:app"]
