import QtQuick
import Quickshell
import "plugin" as Intercom
import "plugin/Model.js" as Model

ShellRoot {
  id: shell

  property bool rowProbePassed: false
  property var probeService: null

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
    visible: true
    opacity: 0
    width: 240
    unread: shell.probeService
      ? Model.messageUnread(shell.probeService.localReadState, "smoke", message)
      : false
    message: ({
      id: "m1",
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
      for (var i = 0; i < widget.children.length; i++) {
        var child = widget.children[i]
        if (typeof child.markConversationRead === "function") shell.probeService = child
      }
      var service = shell.probeService
      if (!service) {
        console.error("intercom qml smoke failed: missing service")
        Qt.quit()
        return
      }
      service.state = "ready"
      service.workspaceId = "smoke"
      service.localReadState = {}
      widget.showingSettings = false
      widget.compositorFocusLost = true
      widget.expandConversationId = "smoke"
      service.threadId = "smoke"
      service.showThread({ id: "smoke", messages: [
        { id: "m1", kind: "customer", body: "First unread message" },
        { id: "m2", kind: "customer", body: "Second unread message" }
      ] })
      service.observeMessages({ id: "other", messages: [
        { id: "m3", kind: "customer", body: "Unread in another conversation" }
      ] }, false)
      service.openConversations = [{ id: "smoke", state: "open" }, { id: "other", state: "open" }]
      widget.pane = "list"
      var dot = null
      for (var j = 0; j < messageProbe.children.length; j++) {
        if (messageProbe.children[j].objectName === "unreadDot") dot = messageProbe.children[j]
      }
      if (!dot || !dot.visible || dot.width <= 0 || !service.barUrgent) {
        console.error("intercom qml smoke failed: unread message missing dot or tray urgency")
        Qt.quit()
        return
      }
      widget.selectInboxIndex(0)
      if (dot.visible || !service.barUrgent || Model.messageUnread(service.localReadState, "smoke", { id: "m2" })
          || !Model.messageUnread(service.localReadState, "other", { id: "m3" }) || widget.pane !== "list") {
        console.error("intercom qml smoke failed: highlighting conversation did not mark all and only its messages read")
        Qt.quit()
        return
      }
      service.showThread({ id: "smoke", messages: [
        { id: "m1", kind: "customer", body: "First message" },
        { id: "m2", kind: "customer", body: "Second message" },
        { id: "m4", kind: "customer", body: "Loaded after highlighting" }
      ] })
      widget.acknowledgeHighlightedConversation()
      if (Model.messageUnread(service.localReadState, "smoke", { id: "m4" })) {
        console.error("intercom qml smoke failed: loaded message in highlighted conversation stayed unread")
        Qt.quit()
        return
      }
      widget.selectInboxIndex(1)
      if (service.barUrgent || Model.messageUnread(service.localReadState, "other", { id: "m3" })) {
        console.error("intercom qml smoke failed: highlighting last unread conversation left tray urgent")
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
