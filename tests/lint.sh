#!/bin/bash

set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
shell_root="${OMARCHY_PATH:-/usr/share/omarchy}/shell"

# Arch also installs Qt 5's qmllint in /usr/bin; Quickshell requires Qt 6.
qmllint=""
candidates=(qmllint6 /usr/lib/qt6/bin/qmllint /usr/lib64/qt6/bin/qmllint qmllint)
if [[ -n "${QMLLINT:-}" ]]; then
  candidates=("$QMLLINT")
fi
for candidate in "${candidates[@]}"; do
  if command -v "$candidate" >/dev/null 2>&1 && [[ $("$candidate" --version 2>&1) == "qmllint 6."* ]]; then
    qmllint=$(command -v "$candidate")
    break
  fi
done
if [[ -z "$qmllint" ]]; then
  printf 'Qt 6 qmllint is required (set QMLLINT to its path).\n' >&2
  exit 1
fi

qt_bin=$(dirname -- "$qmllint")
qt_qml_root=""
for candidate in "$qt_bin/qtpaths6" "$qt_bin/qtpaths" qtpaths6; do
  if command -v "$candidate" >/dev/null 2>&1 && [[ $("$candidate" --query QT_VERSION) == 6.* ]]; then
    qt_qml_root=$("$candidate" --query QT_INSTALL_QML)
    break
  fi
done
if [[ -z "$qt_qml_root" ]]; then
  printf 'Qt 6 qtpaths is required to locate QML imports.\n' >&2
  exit 1
fi

lint_root=$(mktemp -d)
trap 'rm -r -- "$lint_root"' EXIT
# Quickshell resolves qs.* relative to the shell root at runtime.
ln -s -- "$shell_root" "$lint_root/qs"

# Complete Quickshell's generated enum metadata in a temporary import overlay.
# Keep all installed modules and their other types intact; never edit /usr/lib.
python3 - "$qt_qml_root" "$lint_root" "$repo_root/tests/lint/qprocess.qmltypes" <<'PY'
import sys
from pathlib import Path

source = Path(sys.argv[1]) / "Quickshell"
target = Path(sys.argv[2]) / "Quickshell"
target.mkdir()
for entry in source.iterdir():
    if entry.name != "Io":
        (target / entry.name).symlink_to(entry)

io = target / "Io"
io.mkdir()
extra = Path(sys.argv[3]).read_text().split("Module {", 1)[1].rsplit("}", 1)[0]
for entry in (source / "Io").iterdir():
    if entry.name == "qmldir":
        # A symlink would resolve typeinfo relative to the installed module.
        (io / entry.name).write_text(entry.read_text())
    elif entry.suffix == ".qmltypes":
        types = entry.read_text()
        if 'name: "QProcess"' not in types:
            types = types.rsplit("}", 1)[0] + extra + "}\n"
        (io / entry.name).write_text(types)
    else:
        (io / entry.name).symlink_to(entry)
PY

files=("$repo_root"/*.qml "$repo_root"/*.js)
if (($# > 0)); then
  files=("$@")
fi
"$qmllint" --bare -I "$lint_root" -I "$qt_qml_root" --max-warnings 0 "${files[@]}"
printf 'QML lint passed (Qt 6, zero warnings)\n'
