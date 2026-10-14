#!/bin/bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
smoke_root=$(mktemp -d)
trap 'rm -rf -- "$smoke_root"' EXIT

cp -- "$repo_root/tests/qml-smoke.qml" "$smoke_root/shell.qml"
ln -s -- "$repo_root" "$smoke_root/plugin"
ln -s -- /usr/share/omarchy/shell/Commons "$smoke_root/Commons"
ln -s -- /usr/share/omarchy/shell/Ui "$smoke_root/Ui"

set +e
output=$(XDG_CONFIG_HOME="$smoke_root/config" timeout --kill-after=2s 8s quickshell --no-color -p "$smoke_root" 2>&1)
status=$?
set -e
printf '%s\n' "$output"
if ((status != 0)); then
  printf 'quickshell smoke test exited with status %s\n' "$status" >&2
  exit "$status"
fi
grep -q 'intercom qml smoke passed' <<<"$output"
