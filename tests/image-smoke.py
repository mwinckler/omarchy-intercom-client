#!/usr/bin/env python3
"""Exercise Qt's real HTTP image loader without contacting Intercom or the internet."""
import os
import struct
import subprocess
import tempfile
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


PNG = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 1, 8, 2, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(b"\x00" + b"\x30\x90\xd0" * 2)) + chunk(b"IEND", b""))
requests = []


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        requests.append(self.path)
        if self.path.startswith("/slow"):
            time.sleep(0.3)
        missing = self.path.startswith("/missing")
        body = b"Not found" if missing else PNG
        self.send_response(404 if missing else 200)
        self.send_header("Content-Type", "text/plain" if missing else "image/png")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory() as directory:
            smoke = Path(directory)
            (smoke / "shell.qml").write_text((ROOT / "tests/image-smoke.qml").read_text())
            (smoke / "plugin").symlink_to(ROOT)
            shell = Path(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy")) / "shell"
            for name in ("Commons", "Ui"):
                (smoke / name).symlink_to(shell / name)
            result = subprocess.run(
                ["quickshell", "--no-color", "-p", str(smoke)], capture_output=True, text=True, timeout=12,
                env={**os.environ, "XDG_CONFIG_HOME": str(smoke / "config"),
                     "INTERCOM_IMAGE_TEST_URL": f"http://127.0.0.1:{server.server_port}"},
            )
            print(result.stdout + result.stderr)
            assert result.returncode == 0 and "intercom image smoke passed" in result.stdout + result.stderr
            assert sorted(requests) == ["/lazy.png", "/missing.png", "/slow.png"], requests
    finally:
        server.shutdown()
        thread.join()
