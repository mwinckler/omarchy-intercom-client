#!/bin/bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
smoke_root=$(mktemp -d)
trap 'rm -rf -- "$smoke_root"' EXIT

cp -- "$repo_root/tests/qml-smoke.qml" "$smoke_root/shell.qml"
mkdir -- "$smoke_root/plugin"
for source in "$repo_root"/*.qml "$repo_root"/*.js "$repo_root/manifest.json" "$repo_root/LICENSE"; do
  ln -s -- "$source" "$smoke_root/plugin/"
done
# Exercise the real QML and its dialog configuration without live API calls or
# late unconfigured responses closing a composer during the timed dialog tests.
install -m755 -- "$repo_root/tests/qml-smoke-fetch" "$smoke_root/plugin/intercom-fetch"
install -m644 -- "$repo_root/tests/qml-smoke-picker" "$smoke_root/plugin/intercom-file-picker"
ln -s -- /usr/share/omarchy/shell/Commons "$smoke_root/Commons"
ln -s -- /usr/share/omarchy/shell/Ui "$smoke_root/Ui"

set +e
output=$(XDG_CONFIG_HOME="$smoke_root/config" INTERCOM_SMOKE_SLOW_CLOSED=1 timeout --kill-after=2s 8s quickshell --no-color -p "$smoke_root" 2>&1)
status=$?
set -e
printf '%s\n' "$output"
if ((status != 0)); then
  printf 'quickshell smoke test exited with status %s\n' "$status" >&2
  exit "$status"
fi
grep -q 'intercom qml smoke passed' <<<"$output"
