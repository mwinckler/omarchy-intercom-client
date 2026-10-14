#!/usr/bin/env python3
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class LintTests(unittest.TestCase):
    def lint(self, source):
        with tempfile.TemporaryDirectory() as directory:
            qml = Path(directory) / "Probe.qml"
            qml.write_text(source)
            return subprocess.run(
                ["bash", str(ROOT / "tests/lint.sh"), str(qml)],
                capture_output=True, text=True, check=False,
            )

    def test_shell_imports_and_process_enum_resolve(self):
        result = self.lint("""
import QtQuick
import Quickshell.Io
import qs.Commons
Item {
    readonly property var themeFont: Style.font
    property int captionSize: themeFont.caption
    Process { onExited: function(exitCode, exitStatus) {} }
}
""")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stderr, "")

    def test_invalid_qml_and_warnings_fail(self):
        for source in [
            "import QtQuick\nItem {",
            "import QtQuick\nItem { nonexistentProperty: 1 }",
            "import QtQuick\nItem { id: root; property int number: 1; Item { width: number } }",
            "import Missing.Plugin\nItem {}",
            "import Quickshell.Io\nProcess { onExited: function(code, status, extra) {} }",
        ]:
            with self.subTest(source=source):
                result = self.lint(source)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn("QML lint passed", result.stdout)

    def test_explicit_qt5_override_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            fake = Path(directory) / "qmllint"
            fake.write_text("#!/bin/sh\nprintf 'qmllint 1.0\\n'\n")
            fake.chmod(0o755)
            result = subprocess.run(
                ["bash", str(ROOT / "tests/lint.sh")],
                env={**os.environ, "QMLLINT": str(fake)},
                capture_output=True, text=True, check=False,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Qt 6 qmllint is required", result.stderr)


if __name__ == "__main__":
    unittest.main()
