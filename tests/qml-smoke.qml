import QtQuick
import QtQuick.Shapes
import Quickshell
import "plugin" as Intercom
import "plugin/Model.js" as Model

ShellRoot {
  id: shell

  property bool rowProbePassed: false
  property var probeService: null

  function draftStyleMatches(row, highlighted) {
    if (!row || !row.draft || row.border.width !== 0
        || !Qt.colorEqual(row.color, row.alpha(row.draftColor, highlighted ? 0.28 : 0.18))) return false
    for (var i = 0; i < row.children.length; i++) {
      var border = row.children[i]
      if (border.objectName !== "draftBorder") continue
      var path = border.data[0]
      return border.visible && path.strokeStyle === ShapePath.DashLine
        && path.capStyle === ShapePath.RoundCap && path.dashPattern.length === 2
        && path.dashPattern[0] === 0 && path.dashPattern[1] === 3
    }
    return false
  }

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
      service.showThread({ id: "smoke", state: "open", messages: [
        { id: "m1", kind: "customer", body: "First unread message" },
        { id: "m2", kind: "customer", body: "Second unread message" }
      ] })
      service.observeMessages({ id: "other", state: "open", messages: [
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
      service.showThread({ id: "smoke", state: "open", messages: [
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
      var draftConversationId = widget.expandConversationId
      service.messagesLoading = false
      service.showThread({ id: draftConversationId, state: "open", messages: [] })
      service.drafts = Model.setDraft({}, draftConversationId, "Unsent reply", false)
      widget.selectThreadItem("draft")
      var draftRow = widget.threadFocusDelegate()
      if (!draftStyleMatches(draftRow, true) || messageProbe.draft) {
        console.error("intercom qml smoke failed: selected draft styling or sent message changed")
        Qt.quit()
        return
      }
      widget.pane = "list"
      if (!draftStyleMatches(draftRow, false)) {
        console.error("intercom qml smoke failed: unselected draft styling")
        Qt.quit()
        return
      }
      draftRow.pointerHovered = true
      if (!draftStyleMatches(draftRow, true)) {
        console.error("intercom qml smoke failed: hovered draft styling")
        Qt.quit()
        return
      }
      draftRow.pointerHovered = false
      service.drafts = Model.setDraft({}, draftConversationId, "Unsent note", true)
      if (!draftRow.note || !draftStyleMatches(draftRow, false)) {
        console.error("intercom qml smoke failed: note draft styling")
        Qt.quit()
        return
      }
      widget.openComposer()
      if (!widget.composing || !draftRow.note || !draftStyleMatches(draftRow, false)) {
        console.error("intercom qml smoke failed: live draft preview styling")
        Qt.quit()
        return
      }
      widget.stopComposing(true)
      service.scheduled = [{
        id: "scheduled-smoke", conversationId: draftConversationId,
        body: "Scheduled smoke reply", note: false, sendAt: Date.now() + 3600000
      }]
      widget.selectThreadItem("scheduled", "scheduled-smoke", 0)
      var scheduledRow = widget.threadFocusDelegate()
      if (!scheduledRow || scheduledRow.message.body !== "Scheduled smoke reply") {
        console.error("intercom qml smoke failed: scheduled message delegate or model scope")
        Qt.quit()
        return
      }
      widget.selectThreadItem("scheduled-action", "scheduled-smoke", 0)
      var scheduledButton = widget.threadFocusDelegate()
      if (!scheduledButton || scheduledButton.text !== "Cancel scheduled") {
        console.error("intercom qml smoke failed: scheduled action delegate")
        Qt.quit()
        return
      }
      service.scheduled = []
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
      // Non-open messages never create unread dots or tray urgency.
      service.localReadState = {}
      for (var status of ["closed", "snoozed"]) {
        service.showThread({ id: "smoke", state: status, messages: [
          { id: "m1", body: "Not open" }
        ] })
        if (dot.visible || service.barUrgent || service.pendingUrgent.smoke) {
          console.error("intercom qml smoke failed: non-open thread created unread urgency", status)
          Qt.quit()
          return
        }
      }
      var openThread = { id: "smoke", state: "open", messages: [{ id: "status-change", body: "Unread before status change" }] }
      service.threadId = "smoke"
      service.threadCache = Model.writeCachedThread({}, openThread, Date.now())
      service.showThread(openThread)
      service.seedThreadCache([{ id: "smoke", state: "snoozed", messages: [] }])
      if (service.barUrgent || service.thread.state !== "snoozed"
          || service.cachedThread("smoke").conversation.state !== "snoozed"
          || Model.messageUnread(service.localReadState, "smoke", { id: "status-change" })) {
        console.error("intercom qml smoke failed: status-only update left unread urgency or stale cached state")
        Qt.quit()
        return
      }
      service.showThread({ id: "smoke", state: "open", messages: [{ id: "before-close", body: "Unread before closing" }] })
      service.dropClosedConversation("smoke", { id: "smoke", messages: [] })
      if (service.barUrgent || service.thread.state !== "closed"
          || Model.messageUnread(service.localReadState, "smoke", { id: "before-close" })) {
        console.error("intercom qml smoke failed: closing left unread urgency")
        Qt.quit()
        return
      }
      service.threadId = ""
      service.localReadState = { background: { "$background": false } }
      service.inboxFilter = "open"
      service._inboxRequested = "closed"
      service.applyInbox(JSON.stringify({ state: "ready", conversations: [{ id: "background", state: "closed" }] }), 0)
      if (service.barUrgent) {
        console.error("intercom qml smoke failed: inactive inbox response left unread urgency")
        Qt.quit()
        return
      }
      service.localReadState = { open: { "$m1": false }, closed: { "$m1": false }, snoozed: { "$m1": false } }
      service._inboxRequested = "open"
      service.applyInbox(JSON.stringify({ state: "ready", conversations: [{ id: "open", state: "open" }] }), 0)
      if (!service.pendingUrgent.open || service.pendingUrgent.closed || service.pendingUrgent.snoozed) {
        console.error("intercom qml smoke failed: complete Open inbox retained urgency for absent conversations")
        Qt.quit()
        return
      }
      var restored = Model.parseDiskCache(Model.serializeDiskCache({
        state: "ready",
        localReadState: { closed: { "$m1": false }, snoozed: { "$m1": false } },
        threads: Model.writeCachedThread({}, { id: "closed", state: "closed" }, 100),
        inboxes: Model.writeInboxCache({}, "snoozed", [{ id: "snoozed", state: "snoozed" }], 1, 100)
      }))
      service.restoreDiskCache(restored)
      if (service.barUrgent || Model.pendingUrgentCount(service.pendingUrgent) !== 0) {
        console.error("intercom qml smoke failed: restoring non-open threads left unread urgency")
        Qt.quit()
        return
      }
      console.log("intercom qml smoke passed", widget.width, widget.height)
      Qt.quit()
    }
  }
}
