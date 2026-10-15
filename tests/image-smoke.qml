import QtQuick
import Quickshell
import "plugin" as Intercom

ShellRoot {
  id: shell
  readonly property string base: Quickshell.env("INTERCOM_IMAGE_TEST_URL")
  property int step: 0
  property int ticks: 0
  property bool sawLoading: false
  property real reservedHeight: 0
  property string activatedLink: ""
  readonly property var lazyRow: rowRepeater.count > 0 ? rowRepeater.itemAt(0) : null

  function fail(reason) { console.error("intercom image smoke failed:", reason); Qt.quit() }
  function findImage(item) {
    if (item instanceof Intercom.MessageImage) return item
    for (var i = 0; i < item.children.length; i++) {
      var found = findImage(item.children[i])
      if (found) return found
    }
    return null
  }

  Intercom.MessageImage {
    id: ready
    width: 240
    imagesEnabled: true
    image: ({ url: shell.base + "/slow.png", name: "screenshot.png", width: 800, height: 400 })
    onLinkActivated: function(url) { shell.activatedLink = url }
  }
  Intercom.MessageImage {
    id: missing
    width: 240
    imagesEnabled: true
    image: ({ url: shell.base + "/missing.png" })
  }
  Intercom.MessageImage {
    id: hidden
    width: 240
    imagesEnabled: false
    image: ({ url: "https://downloads.intercomcdn.com/must-not-fetch.png" })
  }
  Flickable {
    id: testViewport
    width: 240
    height: 180
    contentHeight: 1400
    Column {
      width: testViewport.width
      Item { width: 1; height: 900 }
      Intercom.MessageImage {
        id: initiallyOffscreen
        width: testViewport.width
        imagesEnabled: true
        viewport: testViewport
        messageRow: initiallyOffscreen
        messageTop: y
        image: ({ url: shell.base + "/must-not-fetch.png", width: 800, height: 400 })
        Component.onCompleted: load()
      }
    }
    Repeater {
      id: rowRepeater
      model: [{ id: "image-only", body: "", blocks: [
        { type: "text", text: "Before <b>image</b>" },
        { type: "image", url: shell.base + "/lazy.png", name: "lazy.png", width: 800, height: 400 },
        { type: "text", text: "After image" }
      ] }]

      Intercom.MessageRow {
        required property var modelData
        required property int index
        y: 900
        width: testViewport.width
        imagesEnabled: true
        imageViewport: testViewport
        // Like the real reader, nested blocks cross the Repeater modelData
        // boundary and arrive as Qt sequences rather than native JS arrays.
        message: modelData
        onLinkActivated: function(url) { shell.activatedLink = url }
      }
    }
  }

  Timer {
    interval: 30
    repeat: true
    running: true
    onTriggered: {
      shell.ticks++
      if (shell.ticks > 200) { shell.fail("timeout at step " + shell.step); return }
      var lazyRow = shell.lazyRow
      if (!lazyRow) return
      var lazy = shell.findImage(lazyRow)
      if (shell.step === 0) {
        if (!lazy) { shell.fail("Repeater message lost its image blocks"); return }
        if (lazyRow.implicitHeight <= 0) return
        if (ready.requested || missing.requested || lazy.requested || hidden.requested || initiallyOffscreen.requested) {
          shell.fail("images fetched without consent or while disabled"); return
        }
        shell.reservedHeight = ready.height
        ready.load()
        missing.load()
        lazy.load()
        shell.step = 1
      } else if (shell.step === 1) {
        if (ready.imageStatus === Image.Loading) shell.sawLoading = true
        if (ready.imageStatus !== Image.Ready || missing.imageStatus !== Image.Error) return
        if (!shell.sawLoading || ready.height !== shell.reservedHeight || lazy.requested) {
          shell.fail("unstable layout, missing loading state, or offscreen download"); return
        }
        shell.reservedHeight = lazyRow.implicitHeight
        initiallyOffscreen.imagesEnabled = false
        testViewport.contentY = 850
        shell.step = 2
      } else if (shell.step === 2) {
        if (lazy.imageStatus !== Image.Ready) return
        if (lazy.width <= 0 || lazy.height <= 0 || lazyRow.imageDiagnostics().length !== 1) {
          shell.fail("image delegate has no visible area"); return
        }
        if (lazyRow.implicitHeight !== shell.reservedHeight) {
          shell.fail("row jumped after image loaded"); return
        }
        lazy.linkActivated(lazy.url)
        if (shell.activatedLink !== shell.base + "/lazy.png") {
          shell.fail("image link not forwarded by message row"); return
        }
        testViewport.width = 120
        shell.step = 3
      } else if (shell.step === 3) {
        if (lazy.width > lazyRow.width || lazy.previewHeight > 280 || lazy.previewHeight <= 0) {
          shell.fail("resized preview escaped message card"); return
        }
        ready.imagesEnabled = false
        testViewport.contentY = 0
        shell.step = 4
      } else if (shell.step === 4) {
        if (lazy.imageStatus !== Image.Null || ready.imageStatus !== Image.Null) {
          shell.fail("hidden images retained their active sources"); return
        }
        console.log("intercom image smoke passed")
        Qt.quit()
      }
    }
  }
}
