#!/bin/bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd -- "$repo_root"

node tests/model.test.mjs
node tests/notification.test.mjs
PYTHONDONTWRITEBYTECODE=1 python3 tests/fetch.test.py
PYTHONDONTWRITEBYTECODE=1 python3 tests/file-picker.test.py
omarchy plugin validate "$repo_root"

bash tests/lint.sh
PYTHONDONTWRITEBYTECODE=1 python3 tests/lint.test.py

bash tests/qml-smoke.sh
PYTHONDONTWRITEBYTECODE=1 python3 tests/image-smoke.py

printf 'all tests passed\n'
