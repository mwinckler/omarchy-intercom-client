import QtQuick
import Quickshell
import "plugin" as Intercom

ShellRoot {
  id: shell

  property bool rowProbePassed: false

  QtObject {
    id: fakeBar
    property color foreground: "#d8dee9"
    property color barForeground: foreground
    property color urgent: "#bf616a"
    property string fontFamily: "monospace"
    property string position: "top"
    property int barSize: 26
    property bool vertical: false
    property bool foregroundAnimationEnabled: false
    property var activePopout: null

    function registerClickTarget(target) {}
    function unregisterClickTarget(target) {}
    function showTooltip(target, text) {}
    function hideTooltip(target) {}
    function requestPopout(target) { activePopout = target }
    function releasePopout(target) { if (activePopout === target) activePopout = null }
    function moduleWidgets(name) { return [] }
    function switchPanelFrom(panel, direction) { return false }
  }

  Intercom.Panel {
    id: widget
    bar: fakeBar
    settings: ({
      refreshIntervalSec: 3600,
      maxConversations: 5,
      tokenFile: "/no/such/intercom-token"
    })
    Component.onCompleted: open()
  }

  Intercom.NetworkPulse {
    id: pulseProbe
    visible: false
    width: 120
    active: false
  }

  Intercom.ConversationRow {
    id: rowProbe
    visible: false
    conversation: ({
      id: "1295",
      title: "Billing question",
      snippet: "Please help",
      from: "Ada Lovelace",
      email: "ada@example.com",
      url: "https://app.intercom.com/a/inbox/abc/inbox/shared/all/conversation/1295",
      waitingSince: 1700000000
    })
    waitingLabel: "2h"
    onActivated: shell.rowProbePassed = true
    Component.onCompleted: activated()
  }

  Intercom.MessageRow {
    id: messageProbe
    visible: false
    message: ({
      id: "1",
      from: "Ada Lovelace",
      email: "ada@example.com",
      kind: "customer",
      createdAt: 1700000000,
      body: "Please <b>help</b> with <i>billing</i><br>See <a href=\"https://example.com\">this</a>"
    })
    timeLabel: "2h"
  }

  Timer {
    interval: 1200
    running: true
    onTriggered: {
      if (!shell.rowProbePassed || widget.width <= 0 || messageProbe.implicitHeight <= 0 || pulseProbe.height !== 2 || !widget.opened) {
        console.error("intercom qml smoke failed", shell.rowProbePassed, widget.width, widget.opened, messageProbe.implicitHeight, pulseProbe.height)
        widget.close()
        Qt.quit()
        return
      }
      widget.compositorFocusLost = true
      widget.toggle()
      if (!widget.opened) {
        console.error("intercom qml smoke failed: unfocused toggle closed the panel")
        Qt.quit()
        return
      }
      widget.toggle()
      if (widget.opened) {
        console.error("intercom qml smoke failed: focused toggle left the panel open")
        widget.close()
        Qt.quit()
        return
      }
      console.log("intercom qml smoke passed", widget.width, widget.height)
      Qt.quit()
    }
  }
}
