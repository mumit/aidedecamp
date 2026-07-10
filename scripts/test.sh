#!/usr/bin/env bash
# Install both packages in editable mode and run the full test suite.
set -euo pipefail
cd "$(dirname "$0")/.."

pip install -e "packages/bearer-openai[dev]"
pip install -e "packages/aidedecamp[dev]"

pytest packages/bearer-openai -q
pytest packages/aidedecamp -q
echo "All tests passed."
