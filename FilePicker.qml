import QtQuick
import Quickshell.Io

Item {
  id: root
  property string pluginRoot: ""
  property string mode: "open"
  property string currentFolder: ""
  property string currentName: "Attachment"
  visible: false
  property bool cancelled: false
  property string request: ""
  readonly property bool running: picker.running

  signal selected(var files)
  signal rejected()
  signal failed(string message)

  function open() {
    if (picker.running) return
    cancelled = false
    visible = true
    request = JSON.stringify({ mode: mode, folder: currentFolder, name: currentName })
    // Use the distro Python: user-managed Python environments may lack Gio.
    picker.command = ["/usr/bin/python3", pluginRoot + "/intercom-file-picker"]
    picker.running = true
  }

  function close() {
    if (!visible && !picker.running) return
    cancelled = true
    visible = false
    if (picker.running) picker.running = false
    root.rejected()
  }

  function applyResult(raw, exitCode) {
    if (cancelled) return
    var result
    try { result = JSON.parse(String(raw || "")) } catch (error) { result = {} }
    if (!result || typeof result !== "object" || Array.isArray(result)) result = {}
    if (exitCode === 0 && result.state === "cancelled") root.rejected()
    else if (exitCode === 0 && result.state === "selected" && Array.isArray(result.files) && result.files.length)
      root.selected(result.files)
    else root.failed(String(result.message || "The system file picker failed. Your draft has been kept. Try again."))
  }

  Process {
    id: picker
    stdinEnabled: true
    stdout: StdioCollector { id: output; waitForEnd: true }
    onStarted: {
      write(root.request + "\n")
      root.request = ""
    }
    onExited: function(exitCode) {
      root.visible = false
      root.applyResult(output.text, exitCode)
    }
  }
}
