import QtQuick
import QtQuick.Shapes
import Quickshell
import "plugin" as Intercom
import "plugin/Model.js" as Model

ShellRoot {
  id: shell

  property bool rowProbePassed: false
  property var probeService: null
  property list<url> selectedUploads: ["file:///home/test/screen%20shot.png", "file:///home/test/log.txt"]
  property int attachmentDialogStage: 0
  property int navigationStage: 0

  function probeInboxOnboarding(service) {
    service.clearSession()
    service.workspaceId = "smoke"
    service.state = "ready"
    service.inboxFilter = "open"
    widget.compositorFocusLost = true
    widget.expandConversationId = "preview"
    if (service.inboxLoaded || !widget.expandedContentLoading) return false

    // Waiting previews can arrive before the complete Open inbox. They must
    // not reveal the sidebar, become selectable, or flash the tray.
    service.applyOutput(JSON.stringify({
      state: "ready", workspaceId: "smoke", openCount: 1,
      conversations: [{ id: "preview", state: "open", messages: [{ id: "preview-message", body: "Old preview" }] }]
    }), 0)
    widget.moveExpanded(0, 1)
    widget.acknowledgeHighlightedConversation()
    if (service.pendingUrgent.preview || service.barUrgent || service.initialReadSeeded
        || service.localReadState.preview["$preview-message"] !== true
        || service.inboxLoaded || !service.openLoading
        || !widget.expandedContentLoading || widget.inboxConversations.length !== 0
        || widget.displayedConversationId() !== "") return false

    // An unrelated response cannot finish loading the selected inbox.
    service._inboxRequested = "closed"
    service.applyInbox(JSON.stringify({ state: "ready", conversations: [] }), 0)
    if (service.inboxLoaded || !widget.expandedContentLoading || service.initialReadSeeded) return false

    // Failed first loads show the error, not previews or an endless spinner.
    service._inboxRequested = "open"
    service.applyInbox(JSON.stringify({ state: "error", message: "Could not load conversations." }), 1)
    service.openLoading = false
    if (service.inboxLoaded || widget.expandedContentLoading || service.initialReadSeeded
        || widget.inboxConversations.length !== 0 || service.openMessage === ""
        || !widget.inboxNavigation.visible) return false

    service.openMessage = ""
    service.openLoading = true
    if (!widget.expandedContentLoading) return false
    service.applyInbox(JSON.stringify({ state: "ready", conversations: [
      { id: "actually-open", state: "open", messages: [{ id: "open-message", body: "Open conversation" }] }
    ] }), 0)
    service.openLoading = false
    if (!service.inboxLoaded || widget.expandedContentLoading
        || widget.inboxConversations.length !== 1
        || widget.inboxConversations[0].id !== "actually-open"
        || service.pendingUrgent.preview || service.barUrgent || !service.initialReadSeeded
        || service.localReadState["actually-open"]["$open-message"] !== true) return false
    service.observeMessages({ id: "actually-open", state: "open", messages: [
      { id: "older-history", createdAt: service.initialReadBefore - 60, body: "History loaded after the inbox" }
    ] }, false)
    if (service.barUrgent || service.localReadState["actually-open"]["$older-history"] !== true) return false
    // Later messages still create unread alerts; the initial load is not a mute.
    service.observeMessages({ id: "actually-open", state: "open", messages: [
      { id: "open-message", body: "Open conversation" },
      { id: "new-message", body: "Arrived after onboarding" }
    ] }, false)
    if (!service.barUrgent || !service.pendingUrgent["actually-open"]
        || !Model.messageUnread(service.localReadState, "actually-open", { id: "new-message" })
        || Model.messageUnread(service.localReadState, "actually-open", { id: "open-message" })) return false
    // Restarting with a complete inbox preserves genuine unread messages.
    var snapshot = Model.parseDiskCache(Model.serializeDiskCache(service.cacheSnapshot()))
    service.restoreDiskCache(snapshot)
    if (!service.initialReadSeeded || service.initialReadBefore !== snapshot.initialReadBefore || !service.barUrgent
        || !Model.messageUnread(service.localReadState, "actually-open", { id: "new-message" })) return false
    service.markConversationRead("actually-open")
    if (widget.inboxConversations.length !== 1 || service.barUrgent) return false

    // Readiness follows the selected source, not the last successful request.
    // Returning from a cached filter must restore Open, not reuse its rows.
    service.inboxFilter = "snoozed"
    if (service.inboxLoaded || !widget.expandedContentLoading
        || widget.inboxConversations.length !== 0) return false
    service.applyInbox(JSON.stringify({ state: "ready", conversations: [
      { id: "actually-open", state: "open" }
    ] }), 0)
    if (service.inboxLoaded || !widget.expandedContentLoading) return false
    service.inboxFilter = "closed"
    if (!service.showCachedInbox() || !service.inboxLoaded
        || widget.expandedContentLoading || widget.inboxConversations.length !== 0) return false
    service.inboxFilter = "open"
    if (!service.showCachedInbox() || !service.inboxLoaded
        || widget.expandedContentLoading || widget.inboxConversations.length !== 1
        || widget.inboxConversations[0].id !== "actually-open") return false

    // Subsequent refreshes keep the confirmed list visible.
    service.openLoading = true
    if (widget.expandedContentLoading) return false
    service.applyInbox(JSON.stringify({ state: "ready", conversations: [] }), 0)
    service.openLoading = false
    if (!service.inboxLoaded || widget.expandedContentLoading
        || widget.inboxConversations.length !== 0) return false

    // Returning users can still open a complete cached inbox immediately,
    // including a successfully fetched inbox with no conversations.
    for (var rows of [[], [{ id: "cached-open", state: "open" }]]) {
      service.clearSession()
      if (service.inboxLoaded || service.initialReadSeeded) return false
      service.workspaceId = "smoke"
      service.state = "ready"
      service.inboxCache = Model.writeInboxCache({}, "open", rows, rows.length, Date.now())
      if (!service.showCachedInbox() || !service.inboxLoaded
          || widget.expandedContentLoading || widget.inboxConversations.length !== rows.length) return false
    }
    service.clearSession()
    service.workspaceId = "smoke"
    service.state = "ready"
    service._inboxRequested = "open"
    service.applyInbox(JSON.stringify({ state: "ready", conversations: [] }), 0)
    widget.expandConversationId = ""
    return true
  }

  function openAttachmentComposer() {
    var conversation = { id: "picker-smoke", state: "open", messages: [] }
    probeService.state = "ready"
    probeService.workspaceId = "smoke"
    probeService.threadCache = Model.writeCachedThread({}, conversation, Date.now())
    probeService.openConversations = [conversation]
    probeService.threadId = conversation.id
    probeService.showThread(conversation)
    probeService.messagesLoading = false
    widget.expandConversationId = conversation.id
    widget.openComposer()
  }

  function probeSpam(service) {
    var spam = { id: "spam", senderId: "sender", state: "open", messages: [{ id: "spam-message", body: "Spam" }] }
    var otherSpam = { id: "other-spam", senderId: "sender", state: "closed" }
    var keep = { id: "keep", senderId: "other", state: "open" }
    service.openConversations = [spam, keep]
    service.conversations = [spam]
    service.threadCache = Model.writeCachedThread({}, spam, Date.now())
    service.inboxCache = Model.writeInboxCache({}, "all", [spam, otherSpam, keep], 3, Date.now())
    service.saveDraft("spam", "Discard me")
    service.scheduled = Model.addScheduled([], "spam", "Do not send", false, Date.now() + 60000)
    service.showThread(spam)
    service.threadId = "spam"
    widget.expandConversationId = "spam"
    widget.requestMarkAsSpam()
    if (!widget.confirmOpen || widget.pendingSpamId !== "spam") return false
    widget.closeConfirmDialog()
    if (widget.confirmOpen || service.markingSpam) return false
    service.dropSpamSender("spam", "sender")
    widget.applySpamSender()
    if (service.openConversations.length !== 1 || service.openConversations[0].id !== "keep"
        || service.threadCache.spam || service.conversations.length || service.threadId !== ""
        || Model.hasDraft(service.drafts, "spam") || service.scheduled.length
        || widget.expandConversationId !== "" || !service.blockedConversations["other-spam"]
        || Model.readInboxCache(service.inboxCache, "all").conversations.length !== 1) return false
    // In-flight responses must not resurrect a blocked sender's messages.
    service._inboxRequested = "open"
    service.applyInbox(JSON.stringify({ state: "ready", conversations: [spam, keep] }), 0)
    service.loadingThreadId = "spam"
    service.applyThread(JSON.stringify({ state: "ready", conversation: spam }), 0)
    if (service.openConversations.length !== 1 || service.threadCache.spam) return false
    service.clearSession()
    service.state = "ready"
    service.workspaceId = "smoke"
    service.initialReadSeeded = true
    service.inboxLoadedSource = "open"
    return true
  }

  function probeInboxPagination(service) {
    if (service.inboxCommand("closed").indexOf("--page") < 0
        || service.inboxCommand("all").indexOf("--page") < 0
        || service.inboxCommand("open").indexOf("--page") >= 0) return false
    service.filterLoaded = false
    service.applyLocalPrefs(JSON.stringify({ filter: "closed" }))
    service._inboxRequested = "closed"
    service._inboxCursor = ""
    service._inboxTimedOut = false
    service.applyInbox(JSON.stringify({ state: "ready", inboxCount: 100000, nextCursor: "page-2",
      conversations: [{ id: "first", state: "closed" }] }), 0)
    service.openLoading = false
    if (!service.inboxLoaded || widget.expandedContentLoading || widget.inboxConversations.length !== 1
        || service.closedCount !== 100000 || service.inboxNextCursor !== "page-2") return false
    service._inboxCursor = "page-2"
    service.applyInbox(JSON.stringify({ state: "error", message: "Page failed" }), 1)
    if (widget.inboxConversations.length !== 1 || service.inboxNextCursor !== "page-2"
        || service.openMessage !== "Page failed") return false
    service.applyInbox(JSON.stringify({ state: "ready", inboxCount: 100000, nextCursor: "page-3",
      conversations: [{ id: "first", state: "closed" }, { id: "second", state: "closed" }] }), 0)
    if (widget.inboxConversations.length !== 2 || service.inboxNextCursor !== "page-3") return false
    var snapshot = Model.parseDiskCache(Model.serializeDiskCache(service.cacheSnapshot()))
    service.restoreDiskCache(snapshot)
    if (service.inboxNextCursor !== "page-3" || widget.inboxConversations.length !== 2) return false
    service._inboxTimedOut = true
    service.applyInbox("", 15)
    if (widget.expandedContentLoading || service.openMessage.indexOf("timed out") < 0
        || widget.inboxConversations.length !== 2) return false
    service._inboxTimedOut = false
    service._inboxCursor = ""
    service.inboxFilter = "open"
    service.inboxLoadedSource = "open"
    service.openConversations = []
    service.openMessage = ""
    service.inboxNextCursor = ""
    service.initialReadSeeded = true
    return true
  }

  function failDialogProbe(message) {
    attachmentDialogProbe.stop()
    console.error("intercom qml smoke failed:", message)
    widget.close()
    Qt.quit()
  }

  function pickerResponse(picker, response) {
    for (var child of picker.data) {
      if (typeof child.write !== "function") continue
      if (String(child.command[0]) !== "/usr/bin/python3"
          || String(child.command[1]).indexOf("/intercom-file-picker") < 0) {
        shell.failDialogProbe("picker did not use the isolated system-portal helper")
        return false
      }
      child.write(JSON.stringify(response) + "\n")
      return true
    }
    shell.failDialogProbe("missing file picker subprocess")
    return false
  }

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
      body: "Please <b>help</b> with <i>billing</i><br>See <a href=\"https://example.com\">this</a>",
      blocks: [{ type: "text", text: "Message with attachment" },
        { type: "attachment", url: "https://example.com/file.pdf", name: "Invoice.pdf", contentType: "application/pdf", size: 1200 }]
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
      if (!shell.probeInboxOnboarding(service)) {
        console.error("intercom qml smoke failed: first inbox loading exposed previews or lost confirmed conversations")
        widget.close()
        Qt.quit()
        return
      }
      if (!shell.probeSpam(service)) {
        shell.failDialogProbe("spam confirmation or sender cleanup failed")
        return
      }
      if (!shell.probeInboxPagination(service)) {
        shell.failDialogProbe("historical inbox pagination, restart, or timeout failed")
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
      var upload = widget.uploadDialog
      var save = widget.saveAttachmentDialog
      if (!upload || !save) {
        console.error("intercom qml smoke failed: attachment dialogs missing")
        Qt.quit()
        return
      }
      if (upload.mode !== "open" || save.mode !== "save") {
        console.error("intercom qml smoke failed: incorrect system picker mode")
        Qt.quit()
        return
      }
      if (!widget.composing || !draftRow.note || !draftStyleMatches(draftRow, false)) {
        console.error("intercom qml smoke failed: live draft preview styling")
        Qt.quit()
        return
      }
      widget.stopComposing(true)
      service.drafts = Model.setDraft({}, draftConversationId, "", true, ["/home/test/log.txt"])
      widget.openComposer()
      widget.attachmentConversationId = widget.replyConversationId
      widget.addAttachments(shell.selectedUploads)
      if (!widget.composing || widget.replyAttachments.length !== 2 || !widget.replyAsNote
          || widget.threadDraftHtml.indexOf("screen shot.png") < 0) {
        console.error("intercom qml smoke failed: attachment-only draft or QML file URL sequence")
        Qt.quit()
        return
      }
      widget.closeComposer()
      widget.openComposer()
      if (widget.replyAttachments.length !== 2 || !widget.selectedHasDraft) {
        console.error("intercom qml smoke failed: attachments did not survive closing composer")
        Qt.quit()
        return
      }
      widget.commitScheduledReply(Date.now() + 3600000)
      var pending = Model.scheduledForConversation(service.scheduled, draftConversationId)
      if (widget.composing || pending.length !== 1 || pending[0].attachments.length !== 2) {
        console.error("intercom qml smoke failed: attachment-only scheduling")
        Qt.quit()
        return
      }
      widget.editScheduledMessage(pending[0].id)
      if (!widget.composing || widget.replyAttachments.length !== 2 || service.scheduled.length !== 0) {
        console.error("intercom qml smoke failed: editing scheduled attachments")
        Qt.quit()
        return
      }
      service.replySent("another-conversation")
      if (!widget.composing || widget.replyAttachments.length !== 2) {
        console.error("intercom qml smoke failed: background send cleared another composer")
        Qt.quit()
        return
      }
      service.replySent(draftConversationId)
      if (widget.composing || widget.replyAttachments.length || Model.hasDraft(service.drafts, draftConversationId)) {
        console.error("intercom qml smoke failed: attachments retained after successful send")
        Qt.quit()
        return
      }
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
      widget.open()
      service.drafts = Model.setDraft({}, "picker-smoke", "Picker draft", true, ["/home/test/log.txt"])
      shell.openAttachmentComposer()
      widget.chooseAttachments()
      attachmentDialogProbe.start()
    }
  }

  Timer {
    id: attachmentDialogProbe
    interval: 200
    repeat: true
    onTriggered: {
      var stage = shell.attachmentDialogStage++
      if (stage === 0) {
        if (!widget.fileDialogOpen || !widget.composing || !widget.uploadDialog.running) {
          shell.failDialogProbe("system picker did not stay open with the composer")
          return
        }
        widget.uploadDialog.close()
        if (widget.fileDialogOpen || widget.replyAttachments.length !== 1
            || widget.threadDraftBody !== "Picker draft" || !widget.replyAsNote) {
          shell.failDialogProbe("canceling attachment picker changed the draft")
          return
        }
      } else if (stage === 1) {
        widget.chooseAttachments()
      } else if (stage === 2) {
        shell.pickerResponse(widget.uploadDialog, { state: "selected", files: [String(Qt.resolvedUrl("plugin/LICENSE"))] })
      } else if (stage === 3) {
        if (widget.fileDialogOpen || widget.replyAttachments.length !== 2
            || widget.threadDraftBody !== "Picker draft" || !widget.replyAsNote) {
          shell.failDialogProbe("system picker selection lost files or draft")
          return
        }
        widget.chooseAttachmentDestination({ name: "../Invoice #1.pdf", url: "https://example.com/file" })
      } else if (stage === 4) {
        if (!widget.saveAttachmentDialog || !widget.saveAttachmentDialog.visible || !widget.opened) {
          shell.failDialogProbe("system save picker did not stay open")
          return
        }
        if (widget.saveAttachmentDialog.currentName !== "Invoice #1.pdf") {
          shell.failDialogProbe("system save picker did not receive a safe suggested filename")
          return
        }
        shell.pickerResponse(widget.saveAttachmentDialog, { state: "cancelled" })
      } else if (stage === 5) {
        widget.chooseAttachments()
      } else if (stage === 6) {
        widget.close()
        if (widget.fileDialogOpen || widget.composing
            || Model.draftEntry(shell.probeService.drafts, "picker-smoke").attachments.length !== 2) {
          shell.failDialogProbe("closing panel with attachment picker lost the draft or left the picker open")
        }
      } else if (stage === 7) {
        widget.open()
        shell.openAttachmentComposer()
        widget.chooseAttachments()
      } else if (stage === 8) {
        shell.pickerResponse(widget.uploadDialog, { state: "error", message: "Picker test failure" })
      } else if (stage === 9) {
        if (widget.fileDialogOpen || shell.probeService.replyMessage !== "Picker test failure"
            || widget.replyAttachments.length !== 2) {
          shell.failDialogProbe("system picker failure was not shown or lost attachments")
          return
        }
        widget.chooseAttachmentDestination({ name: "file.pdf", url: "https://example.com/file" })
      } else if (stage === 10) {
        // An empty/malformed helper response uses a save-specific fallback.
        shell.pickerResponse(widget.saveAttachmentDialog, {})
      } else if (stage === 11) {
        if (!widget.attachmentStatusVisible || shell.probeService.attachmentMessage.indexOf("No attachment was downloaded") < 0
            || shell.probeService.attachmentMessage.indexOf("draft") >= 0
            || shell.probeService.attachmentMessageConversationId !== "picker-smoke"
            || widget.pendingDownloadConversationId !== "" || widget.replyAttachments.length !== 2) {
          shell.failDialogProbe("save picker failure had incorrect context or changed the draft")
          return
        }
        widget.chooseAttachmentDestination({ name: "file.pdf", url: "https://example.com/file" })
        if (widget.attachmentStatusVisible || shell.probeService.attachmentMessage !== "") {
          shell.failDialogProbe("retrying save picker retained the old failure")
          return
        }
      } else if (stage === 12) {
        shell.pickerResponse(widget.saveAttachmentDialog, { state: "cancelled" })
      } else if (stage === 13) {
        if (widget.attachmentStatusVisible || widget.pendingDownloadConversationId !== "") {
          shell.failDialogProbe("canceling save picker retained an error or pending conversation")
          return
        }
        shell.probeService.setAttachmentMessage("Download failed", "picker-smoke")
        if (!widget.attachmentStatusVisible) {
          shell.failDialogProbe("download failure was hidden from its conversation")
          return
        }
        widget.expandConversationId = "other"
        if (widget.attachmentStatusVisible || shell.probeService.attachmentMessage !== "") {
          shell.failDialogProbe("changing conversations retained an attachment failure")
          return
        }
        // A late background download result must not appear in another thread.
        shell.probeService.setAttachmentMessage("Download finished", "picker-smoke")
        if (widget.attachmentStatusVisible) {
          shell.failDialogProbe("background download status leaked into another conversation")
          return
        }
        shell.probeService.setAttachmentMessage("Download failed", "other")
        shell.probeService.clearAttachmentMessage()
        if (widget.attachmentStatusVisible || shell.probeService.attachmentMessage !== "") {
          shell.failDialogProbe("dismissing download status retained the message")
          return
        }
        shell.probeService.setAttachmentMessage("Download failed", "other")
        widget.close()
        if (shell.probeService.attachmentMessage !== "") {
          shell.failDialogProbe("closing panel retained an attachment failure")
          return
        }
        widget.open()
        shell.openAttachmentComposer()
        widget.chooseAttachmentDestination({ name: "file.pdf", url: "https://example.com/file" })
      } else if (stage === 14) {
        widget.close()
      } else {
        if (widget.fileDialogOpen || widget.opened) {
          shell.failDialogProbe("closing panel left a file dialog open")
          return
        }
        stop()
        widget.open()
        widget.closeComposer()
        shell.probeService.inboxCache = Model.writeInboxCache({}, "open", [{ id: "navigation-open", state: "open" }], 1, Date.now())
        shell.probeService.inboxLoadedSource = ""
        shell.probeService.inboxLiveSource = ""
        shell.probeService.pendingInboxMoves = ({})
        shell.probeService.openMessage = ""
        widget.inboxNavigation.children[2].activated()
        navigationProbe.start()
      }
    }
  }

  Timer {
    id: navigationProbe
    interval: 200
    repeat: true
    onTriggered: {
      var service = shell.probeService
      var tabs = widget.inboxNavigation
      if (!tabs.visible || tabs.height <= 0 || !tabs.enabled) {
        shell.failDialogProbe("inbox navigation was hidden or disabled while loading")
        stop()
        return
      }
      if (shell.navigationStage++ === 0) {
        if (!widget.expandedContentLoading || !service.openLoading || service._inboxRequested !== "closed") {
          shell.failDialogProbe("slow Closed inbox did not enter the loading state: "
            + [widget.expandedContentLoading, service.openLoading, service._inboxRequested,
              service.inboxFilter, service.inboxLoaded, service.openConversations.length, service.inboxQueuedSource].join(", "))
          stop()
          return
        }
        tabs.children[0].activated()
        if (service.inboxFilter !== "open" || widget.expandedContentLoading
            || widget.inboxConversations.length !== 1 || widget.inboxConversations[0].id !== "navigation-open") {
          shell.failDialogProbe("switching away from loading did not immediately restore the cached tab")
          stop()
          return
        }
        // Rapid tab changes must retain the latest request, not a stale queued one.
        tabs.children[4].activated()
        tabs.children[0].activated()
      } else {
        stop()
        if (service.openLoading || service._inboxInFlight || !service.inboxLoaded || service.inboxFilter !== "open"
            || service._inboxRequested !== "open" || service.openMessage !== ""
            || Model.readInboxCache(service.inboxCache, "closed").conversations.length) {
          shell.failDialogProbe("canceled Closed request delayed or replaced the selected tab")
          return
        }
        widget.close()
        console.log("intercom qml smoke passed", widget.width, widget.height)
        Qt.quit()
      }
    }
  }
}
