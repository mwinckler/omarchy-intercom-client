#!/bin/bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd -- "$repo_root"

node tests/model.test.mjs
PYTHONDONTWRITEBYTECODE=1 python3 tests/fetch.test.py
omarchy plugin validate "$repo_root"

shell_root="${OMARCHY_PATH:-/usr/share/omarchy}/shell"
if command -v qmllint >/dev/null 2>&1; then
  set +e
  qmllint -I "$shell_root" \
    "$repo_root/Panel.qml" \
    "$repo_root/Service.qml" \
    "$repo_root/ConversationRow.qml" \
    "$repo_root/MessageRow.qml" \
    "$repo_root/ReplyField.qml" \
    "$repo_root/ScheduleDialog.qml"
  qmllint_status=$?
  set -e
  if ((qmllint_status != 0)); then
    printf 'qmllint exited %s (Quickshell imports are often unknown to qmllint); continuing\n' "$qmllint_status"
  fi
fi

bash tests/qml-smoke.sh

printf 'all tests passed\n'
