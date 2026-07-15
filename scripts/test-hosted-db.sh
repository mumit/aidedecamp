#!/usr/bin/env bash
set -euo pipefail

image="pgvector/pgvector:pg16@sha256:1d533553fefe4f12e5d80c7b80622ba0c382abb5758856f52983d8789179f0fb"
container="attune-hosted-db-test-${RANDOM}"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

docker run --rm -d --name "$container" \
  -e POSTGRES_PASSWORD=test-only \
  -e POSTGRES_DB=attune_test \
  -p 127.0.0.1::5432 \
  "$image" >/dev/null

for _ in $(seq 1 30); do
  if docker exec "$container" pg_isready -U postgres -d attune_test \
      >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

port="$(docker port "$container" 5432/tcp | awk -F: '{print $NF}')"
export ATTUNE_TEST_DATABASE_URL="postgresql://postgres:test-only@127.0.0.1:${port}/attune_test"
"$(dirname "$0")/../.venv/bin/python" -m pytest -q tests/test_hosted_db.py
