# The aidedecamp assistant image (roadmap prompt 10).
#
# Build context is the REPO ROOT (both packages are needed):
#   docker build -f packages/aidedecamp/deploy/Dockerfile .
# or let deploy/compose.yml do it: docker compose --profile assistant up.
#
# Installs the app extras only ([orchestrator,memory,google,slack]); the
# republisher keeps its own image (deploy/republisher/Dockerfile) and its own
# dependency set, per the standalone-deployable convention in CLAUDE.md.
#
# No secrets in this image (rule 6): configuration arrives via env_file at
# run time. All mutable state lives under /data (a volume), one ADC_DATA_DIR.

FROM python:3.12-slim

WORKDIR /app

COPY packages/bearer-openai packages/bearer-openai
COPY packages/aidedecamp packages/aidedecamp

RUN pip install --no-cache-dir ./packages/bearer-openai \
    && pip install --no-cache-dir \
       "./packages/aidedecamp[orchestrator,memory,google,slack]"

ENV ADC_DATA_DIR=/data
VOLUME /data

CMD ["python", "-m", "aidedecamp"]
