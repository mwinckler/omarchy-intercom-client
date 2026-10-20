import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import vm from "node:vm";

const model = { console };
vm.createContext(model);
vm.runInContext(fs.readFileSync(new URL("../Model.js", import.meta.url), "utf8")
  .replace(/^\.pragma library\s*/u, ""), model);

// Exercise the installed notifier's argument parser without sending anything
// to the desktop bus. In particular, --exec consumes a vector, not shell text.
const root = fs.mkdtempSync(path.join(process.env.TMPDIR || os.tmpdir(), "intercom-notification-"));
try {
  const log = path.join(root, "busctl.json");
  fs.writeFileSync(path.join(root, "busctl"), `#!/usr/bin/env node
require("node:fs").writeFileSync(process.env.INTERCOM_NOTIFY_TEST_LOG, JSON.stringify(process.argv.slice(2)));
`, { mode: 0o755 });
  for (const row of [
    { id: "123", from: "Ada", snippet: "Please help with billing" },
    { id: "123", from: "--exec", snippet: "--exec" },
    { id: "123", from: "A 'quoted' sender", snippet: "$(touch /not-executed); <b>literal</b> & more" },
    { id: "123", from: "Sender with no body" }
  ]) {
    const command = Array.from(model.notificationCommand(row));
    const result = spawnSync(command[0], command.slice(1), {
      env: { ...process.env, PATH: root + path.delimiter + process.env.PATH, INTERCOM_NOTIFY_TEST_LOG: log },
      encoding: "utf8"
    });
    assert.ifError(result.error);
    assert.equal(result.status, 0, result.stderr);
    const args = JSON.parse(fs.readFileSync(log, "utf8"));
    assert.deepEqual(args.slice(0, 8), ["--user", "--", "call", "org.freedesktop.Notifications",
      "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "Notify", "susssasa{sv}i"]);
    assert.equal(args[8], "Intercom");
    assert.equal(args[11], model.notificationHeadline(row));
    assert.equal(args[12], model.notificationBody(row));
    const exec = args.indexOf("omarchy-exec-argv");
    assert.ok(exec > 0);
    assert.deepEqual(JSON.parse(args[exec + 2]), ["omarchy-shell", "omarchy-intercom-client", "conversation", "123"]);
  }
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
console.log("system notification tests passed");
