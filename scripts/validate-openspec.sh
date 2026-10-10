#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

cd "$REPO_ROOT"

if ! command -v openspec >/dev/null 2>&1; then
  echo "OpenSpec CLI is required. Install @fission-ai/openspec@1.14.1." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Python 3 is required for the OpenSpec validation tests." >&2
  exit 1
fi

echo "OpenSpec CLI: $(openspec --version)"
# Run the focused module directly. Python 3.13 rejects discovery roots that
# are not importable packages; scripts/tests intentionally has no __init__.py.
python3 scripts/tests/test_check_openspec_links.py -v
openspec validate --all --strict
python3 scripts/check_openspec_links.py openspec
