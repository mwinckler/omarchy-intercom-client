import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "intercom-notifier"
  ipcTarget: "intercom-notifier"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property bool barCountsPending: !intercom.countsLoaded

  property bool large: false
  readonly property string sizeShortcutHint: root.large ? "e smaller" : "e larger"
  property bool showingSettings: false
  property bool composing: false
  onComposingChanged: Qt.callLater(root.acknowledgeFocusedMessage)
  property bool replyAsNote: false
  property string replyConversationId: ""
  property string pane: "list"
  property int inboxCursorIndex: 0
  property int threadFocusIndex: -1
  property string threadFocusKey: ""
  property string expandConversationId: ""
  property string pendingExpandId: ""
  property string pendingCloseId: ""
  property string pendingCloseNextId: ""
  property string pendingReopenId: ""
  property bool searchOpen: false
  property bool compositorFocusLost: false
  property bool searchRemote: false
  property string searchQuery: ""
  property int searchCursorIndex: 0
  property var searchResults: []
  readonly property bool searchFieldFocused:
    expandedSearchField ? expandedSearchField.activeFocus : false
  onPaneChanged: {
    if (pane === "thread") root.ensureThreadFocus()
  }
  onExpandConversationIdChanged: {
    threadFocusKey = ""
    threadFocusIndex = -1
    root.closeConfirmDialog()
    root.syncThreadFocus(pane === "thread")
  }
  property bool scrollPendingSelection: false
  property bool pinViewedSelection: false
  property bool filterChordActive: false
  readonly property var inboxRows: Model.includeUnreadConversations(intercom.openConversations, [
    Model.inboxCacheConversations(intercom.inboxCache),
    intercom.conversations,
    Model.cachedConversations(intercom.threadCache)
  ], intercom.localReadState)
  property var inboxConversations: Model.filterInbox(root.inboxRows, intercom.inboxFilter)
  onInboxConversationsChanged: {
    if (root.opened && !root.settingsOpen && !root.searchOpen) root.ensureInboxCursor()
  }
  readonly property bool needsWorkspace: intercom.state === "ready" && String(intercom.workspaceId || "") === ""
  readonly property bool needsSetup: intercom.state === "unconfigured" || intercom.state === "error" || root.needsWorkspace
  readonly property bool signedIn: Model.isSignedIn(intercom.state, intercom.adminName, intercom.adminEmail, intercom.adminId)
  readonly property bool hasAdminProfile: Model.hasAdminProfile(intercom.adminName, intercom.adminEmail)
  readonly property bool settingsOpen: showingSettings || needsSetup
  onSettingsOpenChanged: {
    if (settingsOpen) {
      root.endFilterChord()
      root.closeComposer()
      root.closeSearch()
      root.closeConfirmDialog()
    }
  }
  readonly property bool settingsControlFocused:
    (header.settingsButton ? header.settingsButton.activeFocus : false)
    || (header.signOutButton ? header.signOutButton.activeFocus : false)
    || (header.signInButton ? header.signInButton.activeFocus : false)
    || copyRedirectButton.activeFocus
    || clientIdField.activeFocus
    || clientSecretField.activeFocus
    || signInButton.activeFocus
    || backButton.activeFocus
    || workspaceField.activeFocus
    || tokenField.activeFocus
    || saveTokenButton.activeFocus
  readonly property bool threadMatchesInbox: {
    var conv = inboxConversations.length > 0 && inboxCursorIndex >= 0 && inboxCursorIndex < inboxConversations.length
      ? inboxConversations[inboxCursorIndex]
      : null
    var id = String((conv || {}).id || "")
    return id !== "" && id === String(intercom.threadId || "")
  }
  readonly property bool showingSelectedThread: {
    var threadId = String(intercom.threadId || "")
    if (threadId === "") return false
    if (root.searchOpen) {
      var searchId = String((root.selectedSearchConversation() || {}).id || "")
      return searchId !== "" && threadId === searchId
    }
    var wanted = String(root.expandConversationId || "")
    if (wanted !== "" && threadId === wanted) return true
    return root.threadMatchesInbox
  }
  readonly property bool expandedAreaLoading: !root.searchOpen && intercom.openLoading && inboxConversations.length === 0
  readonly property bool searchRemoteLoading:
    root.searchOpen && root.searchRemote
    && String(root.searchQuery || "").trim() !== ""
    && root.searchResults.length === 0
    && (intercom.searching || archiveSearchTimer.running)
  readonly property bool expandedContentLoading: root.expandedAreaLoading || root.searchRemoteLoading
  readonly property bool threadPaneLoading: {
    if (root.expandedContentLoading) return false
    if (root.showingSelectedThread && intercom.messages.length > 0) return false
    if (root.showingSelectedThread && !intercom.messagesLoading && intercom.threadMessage !== "") return false
    return intercom.messagesLoading
  }
  property double nowMs: Date.now()
  property bool pinThreadToEnd: false
  property bool oauthRedirectCopied: false
  readonly property bool localeMonthFirst: Model.dateFormatMonthFirst(Qt.locale().dateFormat(Locale.ShortFormat))
  readonly property bool scheduleOpen: scheduleDialog ? scheduleDialog.open : false
  property bool cancelConfirmOpen: false
  property string pendingCancelScheduledId: ""
  property string pendingCancelLabel: ""
  readonly property bool confirmOpen: root.cancelConfirmOpen
  readonly property bool overlayOpen: root.scheduleOpen || root.confirmOpen
  onOverlayOpenChanged: Qt.callLater(root.acknowledgeFocusedMessage)

  function alpha(color, amount) { return Qt.rgba(color.r, color.g, color.b, amount) }

  function prefetchVisibleThreads(force) {
    if (!root.opened || root.settingsOpen) return
    var rows = root.searchOpen ? root.searchResults : root.inboxConversations
    var visibleRows = []
    if (inboxFlick) {
      for (var i = 0; i < rows.length; i++) {
        var item = inboxRepeater.itemAt(i)
        if (item && item.y + item.height >= inboxFlick.contentY
            && item.y <= inboxFlick.contentY + inboxFlick.height) visibleRows.push(rows[i])
      }
    }
    var priority = root.searchOpen ? String((root.selectedSearchConversation() || {}).id || "")
      : root.expandConversationId
    intercom.prefetchThreads(visibleRows, priority, force)
  }

  function moveExpanded(dx, dy) {
    if (root.settingsOpen) return
    if (root.searchOpen) {
      if (dx > 0) pane = "thread"
      else if (dx < 0) pane = "list"
      else if (dy !== 0 && pane !== "thread") root.moveSearch(dy)
      else if (dy !== 0) root.moveThreadFocus(dy)
      return
    }
    if (dx < 0) {
      pane = "list"
      return
    }
    if (dx > 0) {
      pane = "thread"
      return
    }
    if (dy === 0) return
    if (pane === "thread") {
      root.moveThreadFocus(dy)
      return
    }
    if (inboxConversations.length === 0) return
    inboxCursorIndex = Math.max(0, Math.min(inboxConversations.length - 1, inboxCursorIndex + dy))
    selectInboxIndex(inboxCursorIndex)
    scrollInboxIntoView()
  }

  function scrollInboxIntoView() {
    Qt.callLater(function() {
      var item = inboxRepeater.itemAt(root.inboxCursorIndex)
      if (!item || !inboxFlick) return
      var margin = Style.space(8)
      var top = item.y
      var bottom = top + Math.max(item.height, item.implicitHeight)
      var maxY = Math.max(0, inboxFlick.contentHeight - inboxFlick.height)
      if (top < inboxFlick.contentY + margin)
        inboxFlick.contentY = Math.max(0, top - margin)
      else if (bottom > inboxFlick.contentY + inboxFlick.height - margin)
        inboxFlick.contentY = Math.min(maxY, bottom + margin - inboxFlick.height)
    })
  }

  function scrollThread(delta) {
    if (!threadFlick) return
    pinThreadToEnd = false
    var step = Style.space(48)
    var maxY = Math.max(0, threadFlick.contentHeight - threadFlick.height)
    threadFlick.contentY = Math.max(0, Math.min(maxY, threadFlick.contentY + delta * step))
  }

  function applyThreadEndScroll() {
    if (!pinThreadToEnd || !threadFlick) return
    var maxY = Math.max(0, threadFlick.contentHeight - threadFlick.height)
    if (threadFlick.contentY !== maxY)
      threadFlick.contentY = maxY
  }

  function scrollThreadToEnd() {
    pinThreadToEnd = true
    applyThreadEndScroll()
    Qt.callLater(root.applyThreadEndScroll)
  }

  function keepReplyLineVisible() {
    Qt.callLater(function() {
      if (!replyFlick || !replyField) return
      var maxY = Math.max(0, replyFlick.contentHeight - replyFlick.height)
      if (maxY <= 0) {
        if (replyFlick.contentY !== 0)
          replyFlick.contentY = 0
        return
      }
      if (replyField.cursorPosition >= replyField.length) {
        if (replyFlick.contentY !== maxY)
          replyFlick.contentY = maxY
        return
      }
      var cr = replyField.cursorRectangle
      var padTop = replyField.topPadding
      var padBottom = replyField.bottomPadding
      var viewTop = replyFlick.contentY
      var viewBottom = viewTop + replyFlick.height
      var lineTop = cr.y
      var lineBottom = cr.y + Math.max(cr.height, 1)
      if (lineTop < viewTop + padTop)
        replyFlick.contentY = Math.max(0, lineTop - padTop)
      else if (lineBottom > viewBottom - padBottom)
        replyFlick.contentY = Math.min(maxY, lineBottom - replyFlick.height + padBottom)
    })
  }

  function ensureInboxCursor() {
    var wanted = String(expandConversationId || "")
    if (wanted === "") {
      inboxCursorIndex = -1
      return
    }
    var selection = Model.resolveInboxSelection(
      root.inboxRows,
      intercom.inboxFilter,
      wanted,
      inboxCursorIndex
    )
    inboxCursorIndex = selection.id !== wanted ? -1 : selection.index
  }

  function selectedInboxConversation() {
    if (inboxConversations.length > 0 && inboxCursorIndex >= 0 && inboxCursorIndex < inboxConversations.length)
      return inboxConversations[inboxCursorIndex]
    return null
  }

  function selectedConversation() {
    return selectedInboxConversation()
  }

  function selectInboxIndex(index) {
    var conversations = inboxConversations
    if (conversations.length === 0) {
      inboxCursorIndex = 0
      expandConversationId = ""
      intercom.loadThread("")
      return
    }
    inboxCursorIndex = Math.max(0, Math.min(conversations.length - 1, index))
    var conv = conversations[inboxCursorIndex] || {}
    var id = String(conv.id || "")
    root.keepReplyOnConversation(id)
    expandConversationId = id
    pinViewedSelection = false
    if (id !== "") intercom.saveViewed(id)
    if (expandConversationId !== "") intercom.loadThread(expandConversationId)
    scrollThreadToEnd()
    Qt.callLater(root.acknowledgeFocusedMessage)
  }

  function expandConversation(conversation) {
    if (settingsOpen) {
      root.saveEnteredToken()
      return
    }
    var conv = conversation || {}
    var id = String(conv.id || "")
    root.keepReplyOnConversation(id)
    expandConversationId = id
    if (id !== "") intercom.saveViewed(id)
    pane = "list"
    if (inboxFlick) inboxFlick.contentY = 0
    intercom.savePanel(root.currentPanelMode())
    intercom.loadInbox()
    if (expandConversationId !== "")
      intercom.loadThread(expandConversationId)
    ensureInboxCursor()
    scrollThreadToEnd()
    Qt.callLater(root.acknowledgeFocusedMessage)
    if (scrollPendingSelection && inboxConversations.length > 0) {
      scrollPendingSelection = false
      scrollInboxIntoView()
    }
  }

  function lookupConversation(conversationId) {
    var id = String(conversationId || "").trim()
    if (id === "") return null
    return Model.findConversationById(intercom.conversations, id)
      || Model.findConversationById(intercom.openConversations, id)
      || { id: id }
  }

  function applyPendingExpand() {
    var id = String(pendingExpandId || "").trim()
    if (id === "") return
    pendingExpandId = ""
    if (settingsOpen) return
    scrollPendingSelection = true
    expandConversation(lookupConversation(id))
  }

  function openExpandedConversation(conversationId) {
    var id = String(conversationId || "").trim()
    if (id === "") {
      open()
      return
    }
    pendingExpandId = id
    if (opened) applyPendingExpand()
    else open()
  }

  function currentPanelMode() {
    return root.large ? "large" : "expanded"
  }

  function applyPanelSize(mode) {
    large = Model.panelMode(mode) === "large"
  }

  function togglePanelMode() {
    if (settingsOpen) return
    var next = Model.nextPanelMode(root.currentPanelMode())
    root.applyPanelSize(next)
    intercom.savePanel(next)
  }

  function restorePreferredPanel() {
    if (!intercom.panelLoaded) return
    root.applyPanelSize(intercom.preferredPanel)
    if (String(pendingExpandId || "") !== "") {
      applyPendingExpand()
      return
    }
    if (needsSetup || showingSettings) return
    if (root.searchOpen) {
      intercom.loadInbox()
      return
    }
    var lastId = String(intercom.lastViewedId || "").trim()
    var lastConv = Model.isSafeConversationId(lastId) ? root.lookupConversation(lastId) : null
    expandConversation(lastConv)
  }

  function restoreSearchView() {
    var field = expandedSearchField
    if (field && field.text !== root.searchQuery) field.text = root.searchQuery
    if (!root.opened || root.settingsOpen) return
    if (root.searchResults.length > 0) {
      root.scrollSearchIntoView()
      root.selectSearchHit()
      keyCatcher.forceActiveFocus()
      return
    }
    if (field) field.forceActiveFocus()
    else keyCatcher.forceActiveFocus()
  }

  function beginFilterChord() {
    if (settingsOpen || searchOpen || composing) return
    filterChordActive = true
  }

  function endFilterChord() {
    filterChordActive = false
  }

  function applyFilterChord(text) {
    var mode = Model.filterChordKey(text)
    endFilterChord()
    if (mode === "") return
    setInboxFilter(mode)
  }

  function clearInboxSelection() {
    inboxCursorIndex = -1
    expandConversationId = ""
    pinViewedSelection = false
    pane = "list"
    root.keepReplyOnConversation("")
    intercom.loadThread("")
  }

  function setInboxFilter(filter) {
    if (settingsOpen) return
    var mode = Model.inboxFilterMode(filter)
    endFilterChord()
    if (intercom.inboxFilter === mode) return
    root.clearInboxSelection()
    intercom.saveFilter(mode)
  }

  function syncInboxSelection() {
    if (root.searchOpen) return
    var wanted = String(expandConversationId || "")
    if (wanted === "") {
      inboxCursorIndex = -1
      if (intercom.openLoading) return
      root.keepReplyOnConversation("")
      intercom.loadThread("")
      return
    }
    var selection = Model.resolveInboxSelection(
      root.inboxRows,
      intercom.inboxFilter,
      wanted,
      inboxCursorIndex
    )
    if (selection.id !== wanted) {
      inboxCursorIndex = -1
      root.keepReplyOnConversation(wanted)
      if (String(intercom.threadId || "") !== wanted)
        intercom.loadThread(wanted)
      root.acknowledgeFocusedMessage()
      return
    }
    inboxCursorIndex = selection.index
    root.keepReplyOnConversation(selection.id)
    if (String(intercom.threadId || "") !== expandConversationId)
      intercom.loadThread(expandConversationId)
    root.acknowledgeFocusedMessage()
  }

  function applyInboxFilter() {
    syncInboxSelection()
    if (inboxFlick) inboxFlick.contentY = 0
    root.prefetchVisibleThreads()
  }

  function saveEnteredToken() {
    var token = tokenField.text
    var workspace = workspaceField.text
    if (String(token || "").replace(/\s+/g, "").trim() === ""
        && String(workspace || "").replace(/\s+/g, "").trim() === "") return
    intercom.saveToken(token, workspace)
  }

  function settingsTabTargets() {
    var items = []
    function add(item) {
      if (!item || !item.visible || !item.enabled) return
      if (item.focusable === false) return
      items.push(item)
    }
    if (root.signedIn && !root.hasAdminProfile) add(header.signInButton)
    if (root.signedIn) add(header.signOutButton)
    add(header.settingsButton)
    add(copyRedirectButton)
    add(clientIdField)
    add(clientSecretField)
    add(signInButton)
    add(backButton)
    add(syncArchiveButton)
    add(workspaceField)
    add(tokenField)
    add(saveTokenButton)
    return items
  }

  function scrollSettingsControlIntoView(item) {
    if (!item || !panelFlick) return
    Qt.callLater(function() {
      if (!item || !panelFlick) return
      var pos = item.mapToItem(panelFlick.contentItem, 0, 0)
      var margin = Style.space(8)
      var top = pos.y
      var bottom = top + Math.max(item.height, item.implicitHeight)
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < panelFlick.contentY + margin)
        panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > panelFlick.contentY + panelFlick.height - margin)
        panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  function focusSettingsControl(direction) {
    var items = root.settingsTabTargets()
    if (items.length === 0) return
    var current = -1
    for (var i = 0; i < items.length; i++) {
      if (items[i].activeFocus) {
        current = i
        break
      }
    }
    var next = current < 0
      ? (direction > 0 ? 0 : items.length - 1)
      : (current + direction + items.length) % items.length
    items[next].forceActiveFocus()
    root.scrollSettingsControlIntoView(items[next])
  }

  function handleSettingsKey(event) {
    if (event.key === Qt.Key_Escape) {
      if (root.needsSetup) keyCatcher.forceActiveFocus()
      else root.closeSettings()
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      var dir = ((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab) ? -1 : 1
      root.focusSettingsControl(dir)
      event.accepted = true
    }
  }

  function focusSettingsField(focusField) {
    var wanted = String(focusField || "")
    if ((wanted === "workspace" || (wanted === "" && root.needsWorkspace)) && workspaceField) {
      workspaceField.forceActiveFocus()
      return
    }
    if (clientIdField) clientIdField.forceActiveFocus()
    else if (tokenField) tokenField.forceActiveFocus()
  }

  function openSettings(focusField) {
    root.closeComposer()
    showingSettings = true
    Qt.callLater(function() {
      if (!root.opened) return
      root.focusSettingsField(focusField)
    })
  }

  function closeSettings() {
    if (needsSetup) {
      close()
      return
    }
    showingSettings = false
    if (tokenField) tokenField.text = ""
    if (workspaceField) workspaceField.text = ""
    if (clientSecretField) clientSecretField.text = ""
    restorePreferredPanel()
    Qt.callLater(function() {
      if (root.opened) keyCatcher.forceActiveFocus()
    })
  }

  function toggleSettings() {
    if (settingsOpen && !needsSetup) closeSettings()
    else openSettings()
  }

  function openSelected() {
    if (settingsOpen) {
      var token = String(tokenField.text || "").replace(/\s+/g, "").trim()
      var workspace = String(workspaceField.text || "").replace(/\s+/g, "").trim()
      if (token !== "" || workspace !== "")
        root.saveEnteredToken()
      else
        root.signInWithIntercom()
      return
    }
    if (pane === "thread") {
      root.activateThreadFocus()
      return
    }
    if (searchOpen) {
      root.activateSearchResult()
      return
    }
    openComposer()
  }

  function composerTargetId() {
    if (root.searchOpen)
      return String((root.selectedSearchConversation() || {}).id || "").trim()
    var wanted = String(expandConversationId || "").trim()
    if (wanted !== "") return wanted
    return String((selectedConversation() || {}).id || "").trim()
  }

  function selectedConversationRecord() {
    var id = root.composerTargetId()
    if (id === "") return null
    if (root.searchOpen) return root.selectedSearchConversation()
    var inbox = Model.findConversationById(inboxConversations, id)
    if (inbox) return inbox
    inbox = Model.findConversationById(intercom.openConversations, id)
    if (inbox) return inbox
    if (String((intercom.thread || {}).id || "") === id) return intercom.thread
    return null
  }

  readonly property bool selectedIsClosed: Model.conversationStateOf(root.selectedConversationRecord()) === "closed"
  readonly property string closeShortcutHint: root.selectedIsClosed ? "c reopen" : "c close"

  function viewedConversationId() {
    var id = root.composerTargetId()
    if (id !== "") return id
    return String(intercom.threadId || "").trim()
  }

  function displayedConversationId() {
    if (!root.opened || root.settingsOpen) return ""
    if (root.searchOpen)
      return String((root.selectedSearchConversation() || {}).id || "").trim()
    return String(root.expandConversationId || "").trim()
  }

  function acknowledgeFocusedMessage() {
    var id = root.displayedConversationId()
    if (id === "" || !root.panelHasKeyboardFocus() || !root.showingSelectedThread
        || root.pane !== "thread" || root.composing || root.overlayOpen) return
    var items = root.threadFocusList
    if (threadFocusIndex < 0 || threadFocusIndex >= items.length) return
    var item = items[threadFocusIndex] || {}
    if (item.kind === "message") intercom.markMessageRead(id, item.index)
  }

  function refreshNow() {
    var id = root.viewedConversationId()
    if (root.searchOpen && id !== "") {
      root.keepReplyOnConversation(id)
      root.expandConversationId = id
    }
    intercom.refreshNow(id)
    if (root.opened && !root.settingsOpen)
      root.prefetchVisibleThreads(true)
  }

  function openSearch() {
    if (settingsOpen) return
    root.closeComposer()
    searchOpen = true
    pane = "list"
    pinViewedSelection = false
    intercom.loadThread("")
    Qt.callLater(function() {
      var field = expandedSearchField
      if (field && field.text !== root.searchQuery) field.text = root.searchQuery
      if (root.opened && field) field.forceActiveFocus()
    })
  }

  function closeSearch() {
    searchOpen = false
    searchQuery = ""
    searchCursorIndex = 0
    searchResults = []
    if (expandedSearchField) expandedSearchField.text = ""
    archiveSearchTimer.stop()
    intercom.archiveSearchHits = []
    intercom.searchMessage = ""
    if (String(expandConversationId || "") !== "") intercom.loadThread(expandConversationId)
    else root.syncInboxSelection()
    root.acknowledgeFocusedMessage()
    Qt.callLater(function() {
      if (root.opened && !root.settingsOpen) keyCatcher.forceActiveFocus()
    })
  }

  function applySearchQuery(text) {
    searchQuery = String(text || "")
    searchCursorIndex = 0
    if (searchRemote) {
      searchResults = []
      if (String(searchQuery || "").trim() === "") {
        archiveSearchTimer.stop()
        intercom.searchMessage = ""
        intercom.archiveSearchHits = []
        return
      }
      archiveSearchTimer.restart()
      return
    }
    searchResults = intercom.localSearchHits(searchQuery)
    if (String(searchQuery || "").trim() === "") {
      archiveSearchTimer.stop()
      intercom.archiveSearchHits = []
      intercom.searchMessage = ""
      return
    }
    archiveSearchTimer.restart()
  }

  function mergeArchiveSearchHits() {
    if (!searchOpen || searchRemote) return
    searchResults = Model.mergeSearchHits(
      intercom.localSearchHits(searchQuery),
      intercom.archiveSearchHits,
      Model.searchLimit()
    )
  }

  function setSearchRemote(remote) {
    if (searchRemote === !!remote) return
    searchRemote = !!remote
    applySearchQuery(searchQuery)
  }

  function toggleSearchRemote() {
    if (!searchOpen) return
    root.setSearchRemote(!searchRemote)
  }

  function focusSearchField() {
    var field = expandedSearchField
    Qt.callLater(function() {
      if (root.opened && root.searchOpen && field) field.forceActiveFocus()
    })
  }

  function scrollSearchIntoView() {
    Qt.callLater(function() {
      var item = inboxRepeater.itemAt(root.searchCursorIndex)
      var flick = inboxFlick
      if (!item || !flick) return
      var pos = item.mapToItem(flick.contentItem, 0, 0)
      var margin = Style.space(8)
      var top = pos.y
      var bottom = top + Math.max(item.height, item.implicitHeight)
      var maxY = Math.max(0, flick.contentHeight - flick.height)
      if (top < flick.contentY + margin)
        flick.contentY = Math.max(0, top - margin)
      else if (bottom > flick.contentY + flick.height - margin)
        flick.contentY = Math.min(maxY, bottom + margin - flick.height)
    })
  }

  function selectSearchHit(conversation) {
    var conv = conversation || selectedSearchConversation() || {}
    var id = String(conv.id || "")
    if (id === "") return
    root.keepReplyOnConversation(id)
    expandConversationId = id
    pinViewedSelection = false
    intercom.saveViewed(id)
    intercom.loadThread(id)
    root.scrollThreadToEnd()
    Qt.callLater(root.acknowledgeFocusedMessage)
    root.prefetchVisibleThreads()
  }

  function focusSearchResults() {
    if (searchResults.length === 0) return false
    searchCursorIndex = Math.max(0, Math.min(searchResults.length - 1, searchCursorIndex))
    pane = "list"
    root.scrollSearchIntoView()
    root.selectSearchHit()
    Qt.callLater(function() {
      if (root.opened && !root.settingsOpen) keyCatcher.forceActiveFocus()
    })
    return true
  }

  function moveSearch(delta) {
    if (searchResults.length === 0) return
    if (delta < 0 && searchCursorIndex <= 0) {
      root.focusSearchField()
      return
    }
    searchCursorIndex = Math.max(0, Math.min(searchResults.length - 1, searchCursorIndex + delta))
    root.scrollSearchIntoView()
    root.selectSearchHit()
  }

  function selectedSearchConversation() {
    if (searchResults.length > 0 && searchCursorIndex >= 0 && searchCursorIndex < searchResults.length)
      return searchResults[searchCursorIndex]
    return null
  }

  function activateSearchResult(conversation) {
    var conv = conversation || selectedSearchConversation()
    if (!conv) return
    expandConversation(conv)
  }

  function handleSearchKey(event) {
    if (event.key === Qt.Key_Escape) {
      root.closeSearch()
      event.accepted = true
      return
    }
    if (root.isComposerControlKey(event, Qt.Key_I)) {
      root.toggleSearchRemote()
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Down || event.key === Qt.Key_Tab) {
      root.focusSearchResults()
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Up || event.key === Qt.Key_Backtab) {
      event.accepted = true
      return
    }
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      if (root.searchRemote && !root.selectedSearchConversation()) {
        archiveSearchTimer.stop()
        var query = String(root.searchQuery || "").trim()
        if (query !== "") intercom.searchConversations(query, true)
      } else {
        root.activateSearchResult()
      }
      event.accepted = true
    }
  }

  function inboxRowUpdatedLabel(conv) {
    var row = conv || {}
    if (Model.formatWaiting(row.waitingSince, root.nowMs) !== "") return ""
    var filter = Model.inboxFilterMode(intercom.inboxFilter)
    var state = String(row.state || "")
    if ((filter === "all" || filter === "open") && (state === "closed" || state === "snoozed"))
      return state
    return Model.formatMessageTime(row.updatedAt, root.nowMs)
  }

  function searchResultWaitingLabel(conv) {
    return Model.formatWaiting((conv || {}).waitingSince, root.nowMs)
  }

  function searchResultUpdatedLabel(conv) {
    var row = conv || {}
    if (root.searchResultWaitingLabel(row) !== "") return ""
    if (String(row.state || "") === "closed") return "closed"
    if (String(row.state || "") === "snoozed") return "snoozed"
    return Model.formatMessageTime(row.updatedAt, root.nowMs)
  }

  function closeSelectedConversation() {
    if (settingsOpen || composing || intercom.closing || intercom.reopening || intercom.replying) return
    var id = root.composerTargetId()
    if (!Model.isSafeConversationId(id)) return
    var list = root.searchOpen ? root.searchResults : inboxConversations
    var next = Model.adjacentConversation(list, id)
    var nextId = next ? String(next.id || "") : ""
    if (nextId === "") {
      var selected = root.searchOpen ? root.selectedSearchConversation() : selectedInboxConversation()
      var selectedId = String((selected || {}).id || "")
      if (selectedId !== "" && selectedId !== id) nextId = selectedId
    }
    pendingCloseId = id
    pendingCloseNextId = nextId
    intercom.closeConversation(id)
  }

  function reopenSelectedConversation() {
    if (settingsOpen || composing || intercom.closing || intercom.reopening || intercom.replying) return
    var id = root.composerTargetId()
    if (!Model.isSafeConversationId(id)) return
    pendingReopenId = id
    intercom.reopenConversation(id)
  }

  function closeOrReopenSelectedConversation() {
    if (Model.conversationStateOf(root.selectedConversationRecord()) === "closed")
      root.reopenSelectedConversation()
    else
      root.closeSelectedConversation()
  }

  function dropClosedSearchResult(closedId, nextId) {
    if (!root.searchOpen) return
    root.searchResults = Model.removeConversation(root.searchResults, closedId)
    var wanted = String(nextId || "")
    var index = root.searchCursorIndex
    if (wanted !== "") {
      for (var i = 0; i < root.searchResults.length; i++) {
        if (String((root.searchResults[i] || {}).id || "") === wanted) {
          index = i
          break
        }
      }
    }
    root.searchCursorIndex = root.searchResults.length === 0
      ? 0
      : Math.max(0, Math.min(root.searchResults.length - 1, index))
  }

  function applyClosedConversation(closedId) {
    var id = String(closedId || "")
    if (id === "" || id !== pendingCloseId) return
    var nextId = pendingCloseNextId
    pendingCloseId = ""
    pendingCloseNextId = ""
    root.dropClosedSearchResult(id, nextId)
    if (String(replyConversationId || "") === id)
      root.stopComposing(true)
    if (nextId !== "") {
      expandConversationId = nextId
      pinViewedSelection = false
      intercom.saveViewed(nextId)
      intercom.loadThread(nextId)
      root.syncInboxSelection()
      root.scrollInboxIntoView()
    } else {
      expandConversationId = ""
      intercom.loadThread("")
    }
  }

  function applyReopenedConversation(reopenedId) {
    var id = String(reopenedId || "")
    if (id === "" || id !== pendingReopenId) return
    pendingReopenId = ""
    if (root.searchOpen)
      root.searchResults = Model.setConversationState(root.searchResults, id, "open")
    expandConversationId = id
    pinViewedSelection = false
    intercom.saveViewed(id)
    root.syncInboxSelection()
  }

  function viewedThreadTitle() {
    if (root.searchOpen) {
      if (!root.showingSelectedThread) return ""
      var hit = root.selectedSearchConversation()
      return hit ? String(hit.title || "") : ""
    }
    var conv = Model.findConversationById(inboxConversations, expandConversationId)
    if (!conv && showingSelectedThread) conv = intercom.thread
    return String((conv || {}).title || "")
  }

  readonly property string threadDraftBody: {
    if (root.composing && replyField)
      return String(replyField.text || "")
    if (root.searchOpen && !root.showingSelectedThread) return ""
    return Model.draftText(intercom.drafts, expandConversationId)
  }
  readonly property string threadDraftHtml: Model.markdownToStyled(threadDraftBody)
  readonly property bool threadDraftIsNote: root.composing
    ? root.replyAsNote
    : Model.draftIsNote(intercom.drafts, expandConversationId)
  readonly property bool selectedHasDraft: Model.draftText(
    intercom.drafts,
    expandConversationId
  ) !== ""
  readonly property var threadScheduled: {
    if (root.searchOpen && !root.showingSelectedThread) return []
    return Model.scheduledForConversation(intercom.scheduled, expandConversationId)
  }
  readonly property var threadFocusList: {
    if (!root.showingSelectedThread) return []
    return Model.threadFocusItems(
      intercom.messages,
      !root.composing && root.threadDraftHtml !== "",
      root.threadScheduled
    )
  }
  readonly property string threadFocusKind: {
    var items = root.threadFocusList
    if (threadFocusIndex < 0 || threadFocusIndex >= items.length) return ""
    return String((items[threadFocusIndex] || {}).kind || "")
  }
  onThreadFocusListChanged: root.syncThreadFocus(root.pane === "thread")

  function syncThreadFocus(preferLast) {
    var resolved = Model.resolveThreadFocus(
      root.threadFocusList,
      threadFocusKey,
      threadFocusIndex,
      !!preferLast
    )
    threadFocusIndex = resolved.index
    threadFocusKey = resolved.key
    Qt.callLater(root.acknowledgeFocusedMessage)
  }

  function ensureThreadFocus() {
    root.syncThreadFocus(true)
    root.scrollThreadFocusIntoView()
  }

  function moveThreadFocus(delta) {
    var next = Model.moveThreadFocus(root.threadFocusList, threadFocusKey, threadFocusIndex, delta)
    threadFocusIndex = next.index
    threadFocusKey = next.key
    root.acknowledgeFocusedMessage()
    pinThreadToEnd = false
    root.scrollThreadFocusIntoView()
  }

  function threadItemSelected(kind, id, index) {
    if (root.composing || root.pane !== "thread") return false
    var items = root.threadFocusList
    if (threadFocusIndex < 0 || threadFocusIndex >= items.length) return false
    var item = items[threadFocusIndex] || {}
    if (String(item.kind || "") !== String(kind || "")) return false
    if (kind === "message") return Number(item.index) === Number(index)
    if (kind === "scheduled" || kind === "scheduled-action")
      return String(item.id || "") === String(id || "")
    return true
  }

  function selectThreadItem(kind, id, index) {
    // A card click restores panel focus even after switching monitors/workspaces.
    root.compositorFocusLost = false
    if (!root.composing && keyCatcher) keyCatcher.forceActiveFocus()
    pane = "thread"
    var items = root.threadFocusList
    var wantedKind = String(kind || "")
    var wantedId = String(id || "")
    for (var i = 0; i < items.length; i++) {
      var item = items[i] || {}
      if (String(item.kind || "") !== wantedKind) continue
      if (wantedKind === "message" && Number(item.index) !== Number(index)) continue
      if ((wantedKind === "scheduled" || wantedKind === "scheduled-action")
          && String(item.id || "") !== wantedId) continue
      threadFocusIndex = i
      threadFocusKey = String(item.key || "")
      root.acknowledgeFocusedMessage()
      root.scrollThreadFocusIntoView()
      return
    }
  }

  function threadFocusDelegate() {
    var items = root.threadFocusList
    if (threadFocusIndex < 0 || threadFocusIndex >= items.length) return null
    var item = items[threadFocusIndex] || {}
    var kind = String(item.kind || "")
    if (kind === "message") return messageRepeater.itemAt(item.index)
    if (kind === "draft") return draftMessageRow
    if (kind === "draft-action") return threadDiscardButton
    var block = scheduledRepeater.itemAt(item.index)
    if (!block) return null
    if (kind === "scheduled") return block.messageRow
    if (kind === "scheduled-action") return block.cancelButton
    return block
  }

  function scrollThreadFocusIntoView() {
    Qt.callLater(function() {
      var item = root.threadFocusDelegate()
      if (!item || !threadFlick) return
      pinThreadToEnd = false
      var pos = item.mapToItem(threadFlick.contentItem, 0, 0)
      var margin = Style.space(8)
      var top = pos.y
      var bottom = top + Math.max(item.height, item.implicitHeight)
      var maxY = Math.max(0, threadFlick.contentHeight - threadFlick.height)
      if (top < threadFlick.contentY + margin)
        threadFlick.contentY = Math.max(0, top - margin)
      else if (bottom > threadFlick.contentY + threadFlick.height - margin)
        threadFlick.contentY = Math.min(maxY, bottom + margin - threadFlick.height)
    })
  }

  function activateThreadFocus() {
    var items = root.threadFocusList
    if (items.length === 0 || threadFocusIndex < 0 || threadFocusIndex >= items.length) {
      root.openComposer()
      return
    }
    var item = items[threadFocusIndex] || {}
    var kind = String(item.kind || "")
    if (kind === "draft-action") {
      root.discardThreadDraft()
      return
    }
    if (kind === "scheduled-action") {
      root.requestCancelScheduled(item.id)
      return
    }
    if (kind === "scheduled") {
      root.editScheduledMessage(item.id)
      return
    }
    root.openComposer()
  }

  function editScheduledMessage(scheduledId) {
    if (settingsOpen) return
    var row = Model.findScheduled(intercom.scheduled, scheduledId)
    if (!row) return
    var id = String(row.conversationId || "").trim()
    if (!Model.isSafeConversationId(id)) return
    var viewed = String(intercom.threadId || "").trim()
    if (viewed !== "" && viewed !== id) return
    if (replyField) replyField.text = String(row.body || "")
    root.replyAsNote = !!row.note
    intercom.replyMessage = ""
    replyConversationId = id
    composing = true
    pane = "thread"
    intercom.cancelScheduled(scheduledId)
    root.scrollThreadToEnd()
    Qt.callLater(function() {
      if (root.opened && replyField) replyField.forceActiveFocus()
    })
  }

  function saveComposerDraft() {
    if (!composing) return
    intercom.saveDraft(replyConversationId, replyField ? replyField.text : "", root.replyAsNote)
  }

  function stopComposing(clearDraft) {
    composing = false
    replyConversationId = ""
    if (clearDraft && replyField) replyField.text = ""
    if (clearDraft) root.replyAsNote = false
  }

  function keepReplyOnConversation(conversationId) {
    var id = String(conversationId || "").trim()
    if (!composing) return
    if (id !== "" && id === String(replyConversationId || "")) return
    root.closeComposer()
  }

  function openComposer() {
    if (settingsOpen) return
    var id = root.composerTargetId()
    if (!Model.isSafeConversationId(id)) return
    var viewed = String(intercom.threadId || "").trim()
    if (viewed !== "" && viewed !== id) return
    var draft = Model.draftText(intercom.drafts, id)
    var asNote = Model.draftIsNote(intercom.drafts, id)
    if (String(replyConversationId || "") !== id && replyField) {
      replyField.text = draft
      root.replyAsNote = asNote
    } else if (replyField && String(replyField.text || "") === "" && draft !== "") {
      replyField.text = draft
      root.replyAsNote = asNote
    }
    intercom.replyMessage = ""
    replyConversationId = id
    composing = true
    pane = "thread"
    root.scrollThreadToEnd()
    Qt.callLater(function() {
      if (root.opened && replyField) replyField.forceActiveFocus()
    })
  }

  function closeComposer() {
    root.closeScheduleDialog()
    root.closeConfirmDialog()
    root.saveComposerDraft()
    root.stopComposing(true)
    Qt.callLater(function() {
      if (root.opened) keyCatcher.forceActiveFocus()
    })
  }

  function discardComposerDraft() {
    root.closeScheduleDialog()
    root.closeConfirmDialog()
    var id = String(replyConversationId || expandConversationId || "").trim()
    intercom.discardDraft(id)
    if (replyField) replyField.text = ""
    root.replyAsNote = false
    root.stopComposing(true)
    Qt.callLater(function() {
      if (root.opened) keyCatcher.forceActiveFocus()
    })
  }

  function discardThreadDraft() {
    if (root.composing) {
      root.discardComposerDraft()
      return
    }
    intercom.discardDraft(expandConversationId)
  }

  function isComposerControlKey(event, key) {
    if (!event || event.key !== key) return false
    if (!(event.modifiers & Qt.ControlModifier)) return false
    if (event.modifiers & Qt.AltModifier) return false
    if (event.modifiers & Qt.ShiftModifier) return false
    return true
  }

  function isDiscardDraftShortcut(event) {
    if (!event || event.key !== Qt.Key_D) return false
    if (!(event.modifiers & Qt.ControlModifier)) return false
    if (!(event.modifiers & Qt.ShiftModifier)) return false
    if (event.modifiers & Qt.AltModifier) return false
    return true
  }

  function applyComposerDeletion(next) {
    if (!replyField || !next) return
    var from = next.cursor
    var to = replyField.cursorPosition
    if (to > from) replyField.remove(from, to)
    replyField.cursorPosition = from
  }

  function deleteComposerLastWord() {
    if (!replyField) return
    root.applyComposerDeletion(Model.deleteLastWord(replyField.text, replyField.cursorPosition))
  }

  function deleteComposerLineBeforeCursor() {
    if (!replyField) return
    root.applyComposerDeletion(Model.deleteLineBeforeCursor(replyField.text, replyField.cursorPosition))
  }

  function discardDraftIfPresent() {
    if (root.settingsOpen) return
    if (root.composing) {
      var text = replyField ? String(replyField.text || "") : ""
      var saved = Model.draftText(intercom.drafts, replyConversationId)
      if (text.trim() === "" && saved === "") return
      root.discardComposerDraft()
      return
    }
    if (Model.draftText(intercom.drafts, expandConversationId) === "") return
    root.discardThreadDraft()
  }

  function sendReply() {
    if (!composing || intercom.replying) return
    var id = String(replyConversationId || "").trim()
    var viewed = String(intercom.threadId || "").trim()
    if (!Model.isSafeConversationId(id)) {
      intercom.replyMessage = "Select a conversation first."
      return
    }
    if (viewed !== id) {
      intercom.replyMessage = "Conversation changed; reply was not sent."
      return
    }
    intercom.reply(id, replyField ? replyField.text : "", root.replyAsNote)
  }

  function closeScheduleDialog() {
    if (scheduleDialog && scheduleDialog.open) scheduleDialog.hide()
  }

  function closeConfirmDialog() {
    cancelConfirmOpen = false
    pendingCancelScheduledId = ""
    pendingCancelLabel = ""
  }

  function requestCancelScheduled(scheduledId) {
    var row = Model.findScheduled(intercom.scheduled, scheduledId)
    if (!row) return
    root.closeScheduleDialog()
    pendingCancelScheduledId = String(row.id || "")
    pendingCancelLabel = Model.formatScheduleTime(row.sendAt)
    if (confirmDialog) confirmDialog.selectedIndex = 1
    cancelConfirmOpen = true
  }

  function commitCancelScheduled() {
    var id = String(pendingCancelScheduledId || "")
    root.closeConfirmDialog()
    if (id === "") return
    intercom.cancelScheduled(id)
    root.syncThreadFocus(true)
    Qt.callLater(function() {
      if (root.opened && !root.settingsOpen) keyCatcher.forceActiveFocus()
    })
  }

  function openScheduleDialog() {
    if (!composing || intercom.replying) return
    if (root.scheduleOpen) return
    root.closeConfirmDialog()
    var text = replyField ? String(replyField.text || "") : ""
    if (text.replace(/\s+/g, "").trim() === "") {
      intercom.replyMessage = "Write a message before sending."
      return
    }
    var id = String(replyConversationId || "").trim()
    var viewed = String(intercom.threadId || "").trim()
    if (!Model.isSafeConversationId(id)) {
      intercom.replyMessage = "Select a conversation first."
      return
    }
    if (viewed !== id) {
      intercom.replyMessage = "Conversation changed; reply was not sent."
      return
    }
    scheduleDialog.show()
  }

  function commitScheduledReply(sendAt) {
    var id = String(replyConversationId || "").trim()
    if (!intercom.scheduleReply(id, replyField ? replyField.text : "", root.replyAsNote, sendAt))
      return
    if (replyField) replyField.text = ""
    intercom.discardDraft(id)
    root.stopComposing(true)
    Qt.callLater(function() {
      if (root.opened) keyCatcher.forceActiveFocus()
    })
  }

  function signInWithIntercom() {
    intercom.login(clientIdField ? clientIdField.text : "", clientSecretField ? clientSecretField.text : "")
  }

  function signOut() {
    if (intercom.signingOut || intercom.signingIn) return
    intercom.signOut()
  }

  function copyOauthRedirectUrl() {
    var value = Model.OAUTH_REDIRECT_URL
    if (value === "") return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(value) + " | wl-copy"])
    root.oauthRedirectCopied = true
    oauthRedirectCopiedTimer.restart()
  }

  function openInBrowser(conversation) {
    var conv = conversation || (root.searchOpen ? selectedSearchConversation() : selectedConversation())
    if (conv)
      openConversation(conv)
    else
      intercom.openInbox()
  }

  function openConversation(conversation) {
    if (String((conversation || {}).url || "").trim() === "") {
      openSettings("workspace")
      return
    }
    close()
    intercom.openConversation(conversation)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (opened) {
      compositorFocusLost = false
      nowMs = Date.now()
      if (!root.searchOpen) {
        pane = "list"
        pinViewedSelection = true
        if (panelFlick) panelFlick.contentY = 0
      } else {
        pinViewedSelection = false
      }
      restorePreferredPanel()
      root.prefetchVisibleThreads()
      Qt.callLater(function() {
        if (root.settingsOpen) {
          root.focusSettingsField()
        } else if (root.searchOpen) {
          root.restoreSearchView()
        } else {
          keyCatcher.forceActiveFocus()
        }
        root.acknowledgeFocusedMessage()
      })
    } else {
      compositorFocusLost = false
      intercom.stopPrefetch()
      root.closeComposer()
      if (!root.needsSetup) showingSettings = false
    }
  }

  Service {
    id: intercom
    settings: root.settings
    onOpenConversationsChanged: {
      if (!root.opened || root.settingsOpen) return
      root.syncInboxSelection()
      root.prefetchVisibleThreads()
      if (root.pinViewedSelection || root.scrollPendingSelection) {
        root.scrollPendingSelection = false
        root.scrollInboxIntoView()
      }
    }
    onMessagesChanged: {
      if (root.opened && root.pinThreadToEnd) root.scrollThreadToEnd()
      Qt.callLater(root.acknowledgeFocusedMessage)
    }
    onNewWaitingMessages: function(conversations) {
      var id = root.displayedConversationId()
      if (id === "" || !Model.findConversationById(conversations, id)) return
      root.scrollThreadToEnd()
    }
    onTokenSaved: {
      tokenField.text = ""
      workspaceField.text = ""
      if (clientSecretField) clientSecretField.text = ""
      root.showingSettings = false
      root.restorePreferredPanel()
    }
    onReplySent: {
      if (replyField) replyField.text = ""
      root.closeComposer()
    }
    onConversationClosed: function(conversationId) {
      root.applyClosedConversation(conversationId)
    }
    onConversationReopened: function(conversationId) {
      root.applyReopenedConversation(conversationId)
    }
    onArchiveSearchHitsChanged: {
      if (!root.searchOpen) return
      if (root.searchRemote) {
        root.searchResults = intercom.archiveSearchHits
        root.searchCursorIndex = 0
      } else {
        root.mergeArchiveSearchHits()
      }
    }
    onInboxFilterChanged: {
      if (root.opened && !root.settingsOpen) root.applyInboxFilter()
    }
    onLastViewedIdChanged: {
      if (root.opened && root.pinViewedSelection && !root.settingsOpen)
        root.restorePreferredPanel()
    }
    onPanelLoadedChanged: {
      if (root.opened && intercom.panelLoaded && !root.settingsOpen)
        root.restorePreferredPanel()
    }
    onSignedOut: {
      root.closeComposer()
      root.closeSearch()
      root.showingSettings = false
      Qt.callLater(function() {
        if (root.opened) root.focusSettingsField()
      })
    }
  }

  function panelHasKeyboardFocus() {
    return root.opened && !root.compositorFocusLost
  }

  function restorePanelKeyboardTarget() {
    if (!root.opened) return
    if (root.settingsOpen) {
      root.focusSettingsField()
      return
    }
    if (root.searchOpen) {
      root.focusSearchField()
      return
    }
    if (root.composing && replyField) {
      replyField.forceActiveFocus()
      return
    }
    if (keyCatcher) keyCatcher.forceActiveFocus()
  }

  function stealPanelFocus() {
    root.compositorFocusLost = false
    Qt.callLater(root.acknowledgeFocusedMessage)
    if (panel) {
      panel.focusPrimed = false
      if (typeof panel.beginFocusPrime === "function") panel.beginFocusPrime()
    }
    Qt.callLater(function() { root.restorePanelKeyboardTarget() })
  }

  function toggle() {
    if (!root.opened) root.open()
    else if (!root.panelHasKeyboardFocus()) root.stealPanelFocus()
    else root.close()
  }

  Connections {
    target: Hyprland
    function onFocusedWorkspaceChanged() {
      if (root.opened) root.compositorFocusLost = true
    }
    function onFocusedMonitorChanged() {
      if (root.opened) root.compositorFocusLost = true
    }
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    function conversation(id: string): string {
      root.openExpandedConversation(id)
      return "ok"
    }
    function status(): string {
      return JSON.stringify({
        implementationVersion: 3,
        state: intercom.state,
        waitingCount: intercom.waitingCount,
        openCount: intercom.openCount,
        conversationCount: intercom.conversations.length,
        inboxConversationCount: root.inboxConversations.length,
        unreadConversationCount: Model.pendingUrgentCount(intercom.pendingUrgent),
        unreadInboxConversationCount: root.inboxConversations.filter(function(row) {
          return !!intercom.pendingUrgent[String(row.id)]
        }).length,
        displayedUnreadMessageCount: intercom.messages.filter(function(msg) {
          return Model.messageUnread(intercom.localReadState, intercom.threadId, msg)
        }).length
      })
    }
  }

  Timer {
    interval: 30000
    repeat: true
    running: root.opened
    onTriggered: root.nowMs = Date.now()
  }

  Timer {
    id: archiveSearchTimer
    interval: root.searchRemote ? 400 : 180
    repeat: false
    onTriggered: {
      if (!root.searchOpen) return
      var query = String(root.searchQuery || "").trim()
      if (query === "") return
      intercom.searchConversations(query, root.searchRemote)
    }
  }

  Timer {
    id: oauthRedirectCopiedTimer
    interval: 1500
    onTriggered: root.oauthRedirectCopied = false
  }

  Shortcut {
    enabled: root.opened && !root.settingsOpen && !root.composing && !root.searchOpen
    sequence: "/"
    onActivated: root.openSearch()
  }

  Shortcut {
    enabled: root.opened && !root.settingsOpen
    sequence: "Ctrl+Shift+D"
    onActivated: root.discardDraftIfPresent()
  }

  Shortcut {
    enabled: root.opened && root.composing && !root.settingsOpen && !root.overlayOpen
    sequence: "Ctrl+S"
    onActivated: root.openScheduleDialog()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.barLabel(
      root.barCountsPending ? 0 : intercom.waitingCount,
      root.barCountsPending ? 0 : intercom.openCount,
      root.vertical)
    labelVisible: !root.barCountsPending
    property bool flashOn: true
    active: intercom.barUrgent && flashOn
    dimmed: false
    activeColor: Color.urgent
    Timer {
      interval: 500
      repeat: true
      running: intercom.barUrgent
      onRunningChanged: button.flashOn = true
      onTriggered: button.flashOn = !button.flashOn
    }
    tooltipText: Model.tooltipText(
      intercom.waitingCount,
      intercom.openCount,
      root.barCountsPending ? "loading" : intercom.state,
      intercom.message)
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) {
        intercom.openInbox()
      } else if (buttonCode === Qt.RightButton) {
        root.refreshNow()
      } else {
        root.toggle()
      }
    }

    Row {
      visible: root.barCountsPending && !root.vertical
      anchors.centerIn: parent
      spacing: Style.space(6)

      Text {
        text: Model.GLYPH
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        renderType: Text.NativeRendering
        verticalAlignment: Text.AlignVCenter
      }

      BarLoadingDots {
        anchors.verticalCenter: parent.verticalCenter
        foreground: button.foreground
        dotSize: Math.max(2, Math.round(button.fontSize * 0.22))
      }
    }

    Column {
      visible: root.barCountsPending && root.vertical
      anchors.centerIn: parent
      spacing: Style.space(2)

      Text {
        anchors.horizontalCenter: parent.horizontalCenter
        text: Model.GLYPH
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: button.fontSize
        renderType: Text.NativeRendering
        horizontalAlignment: Text.AlignHCenter
      }

      BarLoadingDots {
        anchors.horizontalCenter: parent.horizontalCenter
        foreground: button.foreground
        dotSize: Math.max(2, Math.round(button.fontSize * 0.18))
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.large ? Style.space(1400) : Style.space(920))
    contentHeight: panel.cappedContentHeight(root.large ? Style.space(980) : Style.space(700))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (root.confirmOpen) {
          if (dx !== 0 || dy !== 0)
            confirmDialog.selectedIndex = confirmDialog.selectedIndex === 0 ? 1 : 0
          return
        }
        if (root.filterChordActive) root.endFilterChord()
        if (root.searchOpen) {
          if (dy !== 0) root.moveSearch(dy)
          else if (dx > 0) pane = "thread"
          else if (dx < 0) pane = "list"
          return
        }
        root.moveExpanded(dx, dy)
      }
      onActivateRequested: {
        if (root.confirmOpen) {
          if (confirmDialog.selectedIndex === 0) {
            root.closeConfirmDialog()
            Qt.callLater(function() {
              if (root.opened && !root.settingsOpen) keyCatcher.forceActiveFocus()
            })
          } else {
            root.commitCancelScheduled()
          }
          return
        }
        if (root.filterChordActive) {
          root.endFilterChord()
          return
        }
        root.openSelected()
      }
      onCloseRequested: {
        if (root.filterChordActive) {
          root.endFilterChord()
        } else if (root.confirmOpen) {
          root.closeConfirmDialog()
          Qt.callLater(function() {
            if (root.opened && !root.settingsOpen) keyCatcher.forceActiveFocus()
          })
        } else if (root.scheduleOpen) {
          scheduleDialog.requestCancel()
        } else if (root.searchOpen) {
          root.closeSearch()
        } else if (root.composing) {
          root.closeComposer()
        } else if (root.settingsOpen && !root.needsSetup) root.closeSettings()
        else root.close()
      }
      onTabRequested: function(direction) {
        if (root.filterChordActive) root.endFilterChord()
        if (root.confirmOpen) {
          confirmDialog.selectedIndex = confirmDialog.selectedIndex === 0 ? 1 : 0
          return
        }
        if (root.scheduleOpen) {
          scheduleDialog.focusTab(direction)
          return
        }
        if (root.settingsOpen) root.focusSettingsControl(direction)
        else root.switchPanel(direction)
      }
      onTextKey: function(text) {
        if (root.confirmOpen) return
        if (root.filterChordActive) {
          if (text === "f" || text === "F") root.beginFilterChord()
          else root.applyFilterChord(text)
        } else if (root.searchOpen && (text === "i" || text === "I")) {
          root.toggleSearchRemote()
        } else if (text === "s" || text === "S") {
          root.toggleSettings()
        } else if (text === "e" || text === "E") {
          root.togglePanelMode()
        } else if (text === "r" || text === "R") {
          if (root.settingsOpen) return
          root.refreshNow()
        } else if ((text === "f" || text === "F") && !root.searchOpen) {
          root.beginFilterChord()
        } else if (text === "o" || text === "O") {
          if (!root.settingsOpen) root.openInBrowser()
        } else if (text === "c" || text === "C") {
          if (!root.settingsOpen) root.closeOrReopenSelectedConversation()
        } else if (text === "/") {
          if (!root.settingsOpen) root.openSearch()
        }
      }
      blocked: root.settingsControlFocused || replyField.activeFocus
        || root.searchFieldFocused || root.scheduleOpen

      Flickable {
        id: panelFlick
        visible: root.settingsOpen
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: content
          width: panelFlick.width
          spacing: Style.space(12)

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            property Item settingsButton: null
            property Item signOutButton: null
            property Item signInButton: null
            readonly property bool settingsActive: root.settingsOpen
            readonly property bool setupRequired: root.needsSetup
            readonly property bool signedIn: root.signedIn
            readonly property bool signingOut: intercom.signingOut
            readonly property string adminName: intercom.adminName
            readonly property string adminEmail: intercom.adminEmail
            readonly property string adminId: intercom.adminId
            readonly property color accentColor: root.accent
            readonly property color foregroundColor: root.foreground
            function toggleSettings() { root.toggleSettings() }
            function signOut() { root.signOut() }

            PanelHero {
              id: hero
              width: parent.width
              title: "Intercom"
              meta: Model.heroMeta(intercom.state, intercom.message, intercom.waitingCount)
              detail: root.settingsOpen && !root.needsSetup
                ? "SETTINGS"
                : Model.heroDetail(intercom.state, intercom.waitingCount)
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconComponent: Component {
                Text {
                  text: "󰍡"
                  color: intercom.waitingCount > 0 ? root.urgent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                  horizontalAlignment: Text.AlignHCenter
                  verticalAlignment: Text.AlignVCenter
                }
              }
              trailingControl: Component {
                Row {
                  spacing: Style.space(8)

                  ProfileIndicator {
                    visible: header.signedIn
                    showInitials: !header.settingsActive
                    adminName: header.adminName
                    adminEmail: header.adminEmail
                    adminId: header.adminId
                    busy: header.signingOut
                    signingIn: intercom.signingIn
                    focusable: header.settingsActive
                    foreground: header.foregroundColor
                    accent: header.accentColor
                    fontFamily: hero.fontFamily
                    onSignOutRequested: header.signOut()
                    onSignInRequested: root.signInWithIntercom()
                    onSettingsKey: function(event) { root.handleSettingsKey(event) }
                    Component.onCompleted: {
                      header.signOutButton = signOutButton
                      header.signInButton = signInButton
                    }
                    Component.onDestruction: {
                      if (header.signOutButton === signOutButton) header.signOutButton = null
                      if (header.signInButton === signInButton) header.signInButton = null
                    }
                  }

                  PanelActionButton {
                    focusable: header.settingsActive
                    iconText: "󰒓"
                    tooltipText: header.settingsActive && !header.setupRequired
                      ? "Close settings"
                      : (header.signedIn ? "Settings" : "Sign in with Intercom")
                    foreground: header.settingsActive ? header.accentColor : header.foregroundColor
                    fontFamily: hero.fontFamily
                    Keys.onPressed: function(event) { root.handleSettingsKey(event) }
                    onClicked: header.toggleSettings()
                    Component.onCompleted: header.settingsButton = this
                    Component.onDestruction: if (header.settingsButton === this) header.settingsButton = null
                  }
                }
              }
            }
          }

          BorderSurface {
            id: setupBox
            visible: root.settingsOpen
            width: parent.width
            implicitHeight: setupColumn.implicitHeight + Style.space(20)
            color: root.alpha(intercom.state === "error" ? root.urgent : root.foreground, 0.08)
            borderSpec: Border.flat(root.alpha(intercom.state === "error" ? root.urgent : root.foreground, 0.30), 1)
            radius: Style.cornerRadius

            Column {
              id: setupColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.margins: Style.space(10)
              spacing: Style.space(8)

              Text {
                width: parent.width
                visible: Model.statusMessage(intercom.state, intercom.message) !== "" || root.needsWorkspace
                text: root.needsWorkspace
                  ? (intercom.message !== "" ? intercom.message : "Conversation links need your workspace ID.")
                  : Model.statusMessage(intercom.state, intercom.message)
                color: intercom.state === "error" ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              Text {
                width: parent.width
                text: {
                  var name = Model.adminLabel(intercom.adminName, intercom.adminEmail, "")
                  if (name !== "") return "Signed in as " + name + "."
                  return intercom.state === "ready"
                    ? "Sign in with Intercom to reply as yourself. Leave Client ID and secret blank to keep the saved app credentials."
                    : "One teammate creates the Intercom app and enables OAuth. Paste that Client ID and secret, then Sign in with Intercom."
                }
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              Text {
                width: parent.width
                text: "Callback URL to enter in Intercom:"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              Row {
                width: parent.width
                spacing: Style.space(8)

                Text {
                  width: parent.width - copyRedirectButton.implicitWidth - parent.spacing
                  height: Math.max(implicitHeight, copyRedirectButton.height)
                  text: Model.OAUTH_REDIRECT_URL
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WrapAnywhere
                  verticalAlignment: Text.AlignVCenter

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.copyOauthRedirectUrl()
                  }
                }

                Button {
                  id: copyRedirectButton
                  text: root.oauthRedirectCopied ? "Copied" : "Copy"
                  bordered: true
                  focusable: true
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  Keys.onPressed: function(event) { root.handleSettingsKey(event) }
                  onClicked: root.copyOauthRedirectUrl()
                }
              }

              TextField {
                id: clientIdField
                width: parent.width
                enabled: !intercom.signingIn && !intercom.savingToken
                placeholderText: "Client ID"
                foreground: root.foreground
                accent: root.accent
                font.family: root.fontFamily
                onAccepted: clientSecretField.forceActiveFocus()
                Keys.onPressed: function(event) { root.handleSettingsKey(event) }
              }

              TextField {
                id: clientSecretField
                width: parent.width
                password: true
                enabled: !intercom.signingIn && !intercom.savingToken
                placeholderText: intercom.state === "ready" ? "New client secret" : "Client secret"
                foreground: root.foreground
                accent: root.accent
                font.family: root.fontFamily
                onAccepted: root.signInWithIntercom()
                Keys.onPressed: function(event) { root.handleSettingsKey(event) }
              }

              Row {
                spacing: Style.space(8)

                Button {
                  id: signInButton
                  text: intercom.signingIn ? "Waiting…" : "Sign in with Intercom"
                  bordered: true
                  focusable: true
                  enabled: !intercom.signingIn && !intercom.savingToken && !intercom.signingOut
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  Keys.onPressed: function(event) { root.handleSettingsKey(event) }
                  onClicked: root.signInWithIntercom()
                }

                Button {
                  id: backButton
                  visible: !root.needsSetup
                  text: "Back"
                  bordered: true
                  focusable: true
                  enabled: !intercom.signingIn && !intercom.savingToken && !intercom.signingOut
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  Keys.onPressed: function(event) { root.handleSettingsKey(event) }
                  onClicked: root.closeSettings()
                }
              }

              Text {
                width: parent.width
                visible: root.signedIn
                text: "Download every conversation, including closed threads, into a local archive for later search. Closed threads are stored once and are not watched for new replies."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              Button {
                id: syncArchiveButton
                visible: root.signedIn
                text: intercom.syncing ? "Syncing…" : "Sync all conversations"
                bordered: true
                focusable: true
                enabled: root.signedIn && !intercom.syncing && !intercom.signingIn && !intercom.signingOut
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                Keys.onPressed: function(event) { root.handleSettingsKey(event) }
                onClicked: intercom.startArchiveSync()
              }

              Text {
                width: parent.width
                visible: root.signedIn && (intercom.syncing || intercom.syncMessage !== "")
                text: Model.formatSyncProgress(
                  intercom.syncing,
                  intercom.syncScanned,
                  intercom.syncTotal,
                  intercom.syncMessage
                )
                color: intercom.syncState === "error" ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              Text {
                width: parent.width
                text: root.needsWorkspace
                  ? "Could not infer the workspace ID from waiting conversations. Paste any Intercom inbox URL (the segment after /a/inbox/), or grant Read admins and sign in."
                  : "Optional workspace ID or inbox URL, if conversation links do not open."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              TextField {
                id: workspaceField
                width: parent.width
                enabled: !intercom.savingToken && !intercom.signingIn
                placeholderText: "https://app.intercom.com/a/inbox/WORKSPACE/…"
                foreground: root.foreground
                accent: root.accent
                font.family: root.fontFamily
                onAccepted: tokenField.forceActiveFocus()
                Keys.onPressed: function(event) { root.handleSettingsKey(event) }
              }

              Text {
                width: parent.width
                text: "Advanced: paste an OAuth access token if sign-in cannot complete."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }

              TextField {
                id: tokenField
                width: parent.width
                password: true
                enabled: !intercom.savingToken && !intercom.signingIn
                placeholderText: "OAuth access token"
                foreground: root.foreground
                accent: root.accent
                font.family: root.fontFamily
                onAccepted: root.saveEnteredToken()
                Keys.onPressed: function(event) { root.handleSettingsKey(event) }
              }

              Button {
                id: saveTokenButton
                text: intercom.savingToken ? "Saving…" : "Save token or workspace"
                bordered: true
                focusable: true
                enabled: !intercom.savingToken && !intercom.signingIn && (tokenField.text !== "" || workspaceField.text !== "")
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                Keys.onPressed: function(event) { root.handleSettingsKey(event) }
                onClicked: root.saveEnteredToken()
              }
            }
          }

          Text {
            width: parent.width
            text: intercom.reopening
              ? "Reopening conversation…"
              : (intercom.closing
              ? "Closing conversation…"
              : (root.needsSetup ? "Tab next  ·  󰌑 activate  ·  Esc close" : "Tab next  ·  󰌑 activate  ·  Esc back"))
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }
        }
      }

      Item {
        id: expandedView
        visible: !root.settingsOpen
        anchors.fill: parent

        Column {
          id: expandedHeader
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          spacing: Style.space(4)

          Item {
            width: parent.width
            implicitHeight: Math.max(
              expandedTitle.implicitHeight,
              expandedProfile.visible ? expandedProfile.implicitHeight : 0,
              expandedSettings.implicitHeight
            )

            Text {
              id: expandedTitle
              anchors.left: parent.left
              anchors.right: expandedProfile.visible ? expandedProfile.left : expandedSettings.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: "Intercom"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
            }

            ProfileIndicator {
              id: expandedProfile
              visible: root.signedIn
              width: visible ? implicitWidth : 0
              anchors.right: expandedSettings.left
              anchors.rightMargin: visible ? Style.space(8) : 0
              anchors.verticalCenter: parent.verticalCenter
              adminName: intercom.adminName
              adminEmail: intercom.adminEmail
              adminId: intercom.adminId
              busy: intercom.signingOut
              signingIn: intercom.signingIn
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onSignOutRequested: root.signOut()
              onSignInRequested: root.signInWithIntercom()
            }

            PanelActionButton {
              id: expandedSettings
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰒓"
              tooltipText: "Settings"
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.openSettings()
            }
          }

          Column {
            visible: root.searchOpen
            width: parent.width
            spacing: Style.space(6)

            TextField {
              id: expandedSearchField
              width: parent.width
              placeholderText: root.searchRemote ? "Search Intercom…" : "Search cached conversations…"
              foreground: root.foreground
              accent: root.accent
              font.family: root.fontFamily
              onTextChanged: if (activeFocus) root.applySearchQuery(text)
              Keys.priority: Keys.BeforeItem
              Keys.onPressed: function(event) { root.handleSearchKey(event) }
            }

            Row {
              spacing: Style.space(8)

              FilterChip {
                label: "LOCAL"
                chosen: !root.searchRemote
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                onActivated: root.setSearchRemote(false)
              }

              FilterChip {
                label: "INTERCOM"
                chosen: root.searchRemote
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                onActivated: root.setSearchRemote(true)
              }
            }
          }

          Flow {
            width: parent.width
            spacing: Style.space(8)
            visible: !root.expandedAreaLoading && !root.searchOpen

            FilterChip {
              label: "OPEN"
              countText: String(intercom.openCount)
              shortcut: "o"
              shortcutVisible: root.filterChordActive
              chosen: Model.inboxFilterMode(intercom.inboxFilter) === "open"
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onActivated: root.setInboxFilter("open")
            }

            FilterChip {
              label: "WAITING"
              countText: String(intercom.waitingCount)
              shortcut: "w"
              shortcutVisible: root.filterChordActive
              chosen: Model.inboxFilterMode(intercom.inboxFilter) === "waiting"
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onActivated: root.setInboxFilter("waiting")
            }

            FilterChip {
              label: "CLOSED"
              countText: String(intercom.closedCount)
              shortcut: "c"
              shortcutVisible: root.filterChordActive
              chosen: Model.inboxFilterMode(intercom.inboxFilter) === "closed"
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onActivated: root.setInboxFilter("closed")
            }

            FilterChip {
              label: "SNOOZED"
              countText: String(intercom.snoozedCount)
              shortcut: "s"
              shortcutVisible: root.filterChordActive
              chosen: Model.inboxFilterMode(intercom.inboxFilter) === "snoozed"
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onActivated: root.setInboxFilter("snoozed")
            }

            FilterChip {
              label: "ALL"
              countText: String(intercom.allCount)
              shortcut: "a"
              shortcutVisible: root.filterChordActive
              chosen: Model.inboxFilterMode(intercom.inboxFilter) === "all"
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onActivated: root.setInboxFilter("all")
            }
          }

          Text {
            width: parent.width
            visible: root.searchOpen && !root.searchRemoteLoading && root.searchResults.length === 0 && (intercom.searchMessage !== "" || intercom.searching || String(root.searchQuery || "").trim() !== "")
            text: intercom.searching
              ? "Searching archive…"
              : (intercom.searchMessage !== ""
                ? intercom.searchMessage
                : "No conversations matched.")
            color: intercom.searchMessage.indexOf("Could not") >= 0 ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            visible: !root.searchOpen && intercom.openMessage !== ""
            text: intercom.openMessage
            color: intercom.openMessage.indexOf("Could not") >= 0 ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        Text {
          id: expandedHint
          anchors.bottom: parent.bottom
          width: parent.width
          text: intercom.reopening
            ? "Reopening conversation…"
            : (intercom.closing
            ? "Closing conversation…"
            : (root.searchOpen
              ? (root.pane === "thread"
                ? "j/k messages  ·  h/l panes  ·  󰌑 reply or edit  ·  Esc close search"
                : "↓/Tab results  ·  i/Ctrl+I Intercom  ·  j/k navigate  ·  󰌑 open  ·  h/l panes  ·  Esc close search")
              : (root.composing
              ? "Ctrl+󰌑 send now  ·  Ctrl+S later  ·  Esc save draft  ·  Ctrl+Shift+D discard  ·  Ctrl+N note"
              : (root.pane === "thread"
                ? ((root.threadFocusKind === "draft" || root.threadFocusKind === "scheduled")
                  ? "j/k messages  ·  h/l panes  ·  f filter  ·  " + root.sizeShortcutHint + "  ·  󰌑 edit  ·  Ctrl+Shift+D discard  ·  o open  ·  " + root.closeShortcutHint + "  ·  / search  ·  r refresh  ·  Esc close"
                  : (root.threadFocusKind === "draft-action" || root.threadFocusKind === "scheduled-action"
                    ? "j/k messages  ·  h/l panes  ·  f filter  ·  " + root.sizeShortcutHint + "  ·  󰌑  ·  o open  ·  " + root.closeShortcutHint + "  ·  / search  ·  r refresh  ·  Esc close"
                    : (root.selectedHasDraft
                      ? "j/k messages  ·  h/l panes  ·  f filter  ·  " + root.sizeShortcutHint + "  ·  󰌑 reply  ·  Ctrl+Shift+D discard  ·  o open  ·  " + root.closeShortcutHint + "  ·  / search  ·  r refresh  ·  Esc close"
                      : "j/k messages  ·  h/l panes  ·  f filter  ·  " + root.sizeShortcutHint + "  ·  󰌑 reply  ·  o open  ·  " + root.closeShortcutHint + "  ·  / search  ·  r refresh  ·  Esc close")))
                : (root.selectedHasDraft
                ? "j/k list  ·  h/l panes  ·  f filter  ·  " + root.sizeShortcutHint + "  ·  󰌑 edit draft  ·  Ctrl+Shift+D discard  ·  o open  ·  " + root.closeShortcutHint + "  ·  / search  ·  r refresh  ·  Esc close"
                : "j/k list  ·  h/l panes  ·  f filter  ·  " + root.sizeShortcutHint + "  ·  󰌑 reply  ·  o open  ·  " + root.closeShortcutHint + "  ·  / search  ·  r refresh  ·  Esc close")))))
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
        }

        BorderSurface {
          visible: root.expandedContentLoading
          anchors.top: expandedHeader.bottom
          anchors.bottom: expandedHint.top
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.topMargin: Style.space(12)
          anchors.bottomMargin: Style.space(8)
          color: "transparent"
          borderSpec: Border.flat(root.alpha(root.foreground, 0.13), 1)
          radius: Style.cornerRadius

          LoadingMark {
            anchors.centerIn: parent
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            label: root.searchRemoteLoading ? "Searching Intercom…" : "Loading conversations…"
          }
        }

        Row {
          id: splitRow
          visible: !root.expandedContentLoading
          anchors.top: expandedHeader.bottom
          anchors.bottom: expandedHint.top
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.topMargin: Style.space(12)
          anchors.bottomMargin: Style.space(8)
          spacing: Style.space(12)

          BorderSurface {
            width: Style.space(280)
            height: parent.height
            color: "transparent"
            borderSpec: root.pane === "list"
              ? Border.controlSpec("normal", root.foreground, root.accent)
              : Border.flat(root.alpha(root.foreground, 0.13), 1)
            radius: Style.cornerRadius
            clip: true

            NetworkPulse {
              z: 10
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              active: !root.searchOpen && intercom.openLoading
              accent: root.accent
            }

            Flickable {
              id: inboxFlick
              anchors.fill: parent
              anchors.margins: Style.space(6)
              contentWidth: width
              contentHeight: inboxColumn.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              flickableDirection: Flickable.VerticalFlick
              interactive: contentHeight > height
              onContentYChanged: Qt.callLater(root.prefetchVisibleThreads)
              onContentHeightChanged: Qt.callLater(root.prefetchVisibleThreads)
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

              Column {
                id: inboxColumn
                width: inboxFlick.width
                spacing: Style.space(8)

                Text {
                  width: parent.width
                  visible: !intercom.openLoading && (root.searchOpen ? root.searchResults.length === 0 && String(root.searchQuery || "").trim() === "" : inboxConversations.length === 0)
                  text: root.searchOpen
                    ? "Type to search."
                    : (intercom.openMessage !== ""
                    ? intercom.openMessage
                    : Model.emptyInboxMessage(intercom.inboxFilter))
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }

                Repeater {
                  id: inboxRepeater
                  model: root.searchOpen ? root.searchResults : inboxConversations

                  ConversationRow {
                    required property int index
                    required property var modelData
                    width: inboxColumn.width
                    conversation: modelData
                    unread: !!intercom.pendingUrgent[String(modelData.id)]
                    waitingLabel: root.searchOpen
                      ? root.searchResultWaitingLabel(modelData)
                      : Model.formatWaiting(modelData.waitingSince, root.nowMs)
                    updatedLabel: root.searchOpen
                      ? root.searchResultUpdatedLabel(modelData)
                      : root.inboxRowUpdatedLabel(modelData)
                    selected: root.searchOpen ? root.searchCursorIndex === index : root.inboxCursorIndex === index
                    hasDraft: Model.draftText(intercom.drafts, modelData.id) !== ""
                    hasScheduled: Model.hasScheduled(intercom.scheduled, modelData.id)
                    foreground: root.foreground
                    accent: root.accent
                    urgent: root.urgent
                    fontFamily: root.fontFamily
                    onActivated: {
                      if (root.searchOpen) {
                        root.searchCursorIndex = index
                        root.selectSearchHit(modelData)
                      } else {
                        root.selectInboxIndex(index)
                      }
                    }
                  }
                }
              }
            }
          }

          BorderSurface {
            id: threadPane
            width: splitRow.width - Style.space(280) - splitRow.spacing
            height: parent.height
            color: "transparent"
            borderSpec: root.pane === "thread"
              ? Border.controlSpec("normal", root.foreground, root.accent)
              : Border.flat(root.alpha(root.foreground, 0.13), 1)
            radius: Style.cornerRadius

            Flickable {
              id: threadFlick
              visible: !root.threadPaneLoading
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: composerBox.top
              anchors.margins: Style.space(8)
              anchors.bottomMargin: root.composing ? Style.space(4) : Style.space(8)
              contentWidth: width
              contentHeight: threadColumn.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              flickableDirection: Flickable.VerticalFlick
              interactive: contentHeight > height
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
              onContentHeightChanged: root.applyThreadEndScroll()
              onHeightChanged: root.applyThreadEndScroll()
              onMovementStarted: root.pinThreadToEnd = false

              Column {
                id: threadColumn
                width: threadFlick.width
                spacing: Style.space(10)

                Text {
                  width: parent.width
                  visible: root.viewedThreadTitle() !== ""
                  text: root.viewedThreadTitle()
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                  wrapMode: Text.WordWrap
                }

                Text {
                  width: parent.width
                  visible: !intercom.messagesLoading && intercom.threadMessage !== "" && root.showingSelectedThread
                  text: intercom.threadMessage
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }

                Repeater {
                  id: messageRepeater
                  model: root.showingSelectedThread ? intercom.messages : []

                  MessageRow {
                    required property var modelData
                    required property int index
                    width: threadColumn.width
                    message: modelData
                    unread: Model.messageUnread(intercom.localReadState, intercom.threadId, modelData)
                    unreadColor: root.urgent
                    selected: root.threadItemSelected("message", modelData.id, index)
                    timeLabel: Model.formatMessageTime(modelData.createdAt, root.nowMs)
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onActivated: root.selectThreadItem("message", modelData.id, index)
                    onLinkActivated: function(url) {
                      if (Model.isSafeHttpUrl(url)) intercom.openUrl(url)
                    }
                  }
                }

                Column {
                  width: parent.width
                  visible: root.threadDraftHtml !== ""
                  spacing: Style.space(6)

                  MessageRow {
                    id: draftMessageRow
                    width: parent.width
                    message: ({
                      from: Model.adminLabel(intercom.adminName, intercom.adminEmail, "You"),
                      email: String(intercom.adminEmail || ""),
                      kind: root.threadDraftIsNote ? "note" : "teammate",
                      body: root.threadDraftHtml
                    })
                    badge: root.composing ? (root.threadDraftIsNote ? "NOTE" : "") : "DRAFT"
                    selected: root.threadItemSelected("draft")
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onActivated: root.selectThreadItem("draft")
                    onLinkActivated: function(url) {
                      if (Model.isSafeHttpUrl(url)) intercom.openUrl(url)
                    }
                  }

                  Button {
                    id: threadDiscardButton
                    visible: !root.composing
                    text: "Discard draft"
                    tooltipText: "Ctrl+Shift+D"
                    bordered: true
                    selected: root.threadItemSelected("draft-action")
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    onClicked: {
                      root.selectThreadItem("draft-action")
                      root.discardThreadDraft()
                    }
                  }
                }

                Repeater {
                  id: scheduledRepeater
                  model: root.threadScheduled

                  Column {
                    required property var modelData
                    required property int index
                    property alias messageRow: scheduledMessage
                    property alias cancelButton: scheduledCancel
                    width: threadColumn.width
                    spacing: Style.space(6)

                    MessageRow {
                      id: scheduledMessage
                      width: parent.width
                      message: ({
                        from: Model.adminLabel(intercom.adminName, intercom.adminEmail, "You"),
                        email: String(intercom.adminEmail || ""),
                        kind: modelData.note ? "note" : "teammate",
                        body: Model.markdownToStyled(modelData.body)
                      })
                      badge: "LATER · " + Model.formatScheduleTime(modelData.sendAt)
                      selected: root.threadItemSelected("scheduled", modelData.id, index)
                      foreground: root.foreground
                      accent: root.accent
                      fontFamily: root.fontFamily
                      onActivated: root.selectThreadItem("scheduled", modelData.id, index)
                      onLinkActivated: function(url) {
                        if (Model.isSafeHttpUrl(url)) intercom.openUrl(url)
                      }
                    }

                    Button {
                      id: scheduledCancel
                      text: "Cancel scheduled"
                      bordered: true
                      selected: root.threadItemSelected("scheduled-action", modelData.id, index)
                      foreground: root.foreground
                      accent: root.accent
                      fontFamily: root.fontFamily
                      fontSize: Style.font.caption
                      onClicked: {
                        root.selectThreadItem("scheduled-action", modelData.id, index)
                        root.requestCancelScheduled(modelData.id)
                      }
                    }
                  }
                }
              }
            }

            Column {
              id: composerBox
              visible: root.composing && !root.threadPaneLoading
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              anchors.margins: Style.space(8)
              spacing: Style.space(6)
              height: visible ? Math.min(implicitHeight, Math.max(0, parent.height - Style.space(8) * 2)) : 0
              clip: true

              Row {
                width: parent.width
                spacing: Style.space(8)

                Text {
                  visible: Model.adminLabel(intercom.adminName, intercom.adminEmail, "") !== ""
                  width: visible ? parent.width - replyModeRow.width - parent.spacing : 0
                  height: Math.max(implicitHeight, replyModeRow.height)
                  text: (root.replyAsNote ? "Note as " : "Replying as ")
                    + Model.adminLabel(intercom.adminName, intercom.adminEmail, "")
                  color: root.replyAsNote ? root.dim : root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                  verticalAlignment: Text.AlignVCenter
                }

                Row {
                  id: replyModeRow
                  spacing: Style.space(6)

                  FilterChip {
                    label: "REPLY"
                    chosen: !root.replyAsNote
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onActivated: root.replyAsNote = false
                  }

                  FilterChip {
                    label: "NOTE"
                    chosen: root.replyAsNote
                    foreground: root.foreground
                    accent: root.accent
                    fontFamily: root.fontFamily
                    onActivated: root.replyAsNote = true
                  }
                }
              }

              Flickable {
                id: replyFlick
                width: parent.width
                readonly property real maxHeight: Math.max(Style.space(48), Math.floor(threadPane.height / 2))
                readonly property real minHeight: Math.min(Style.space(96), maxHeight)
                height: Math.min(Math.max(replyField.implicitHeight, minHeight), maxHeight)
                implicitHeight: height
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick
                interactive: contentHeight > height
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                onContentHeightChanged: root.keepReplyLineVisible()
                onHeightChanged: root.keepReplyLineVisible()

                TextArea.flickable: ReplyField {
                  id: replyField
                  width: replyFlick.width
                  enabled: !intercom.replying
                  placeholderText: root.replyAsNote ? "Internal note" : "**bold**  *italic*  [text](url)"
                  foreground: root.foreground
                  accent: root.accent
                  onCursorRectangleChanged: root.keepReplyLineVisible()
                  onTextChanged: {
                    if (root.composing) root.scrollThreadToEnd()
                  }
                  Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Escape) {
                      root.closeComposer()
                      event.accepted = true
                    } else if (root.isDiscardDraftShortcut(event)) {
                      root.discardDraftIfPresent()
                      event.accepted = true
                    } else if (root.isComposerControlKey(event, Qt.Key_N)) {
                      root.replyAsNote = !root.replyAsNote
                      event.accepted = true
                    } else if (root.isComposerControlKey(event, Qt.Key_W)) {
                      root.deleteComposerLastWord()
                      event.accepted = true
                    } else if (root.isComposerControlKey(event, Qt.Key_U)) {
                      root.deleteComposerLineBeforeCursor()
                      event.accepted = true
                    } else if (root.isComposerControlKey(event, Qt.Key_S)) {
                      root.openScheduleDialog()
                      event.accepted = true
                    } else if (root.isComposerControlKey(event, Qt.Key_Return)
                        || root.isComposerControlKey(event, Qt.Key_Enter)) {
                      root.sendReply()
                      event.accepted = true
                    }
                  }
                }
              }

              Text {
                width: parent.width
                visible: intercom.replyMessage !== ""
                text: intercom.replyMessage
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              Row {
                width: parent.width
                spacing: Style.space(8)

                Button {
                  id: sendNowButton
                  text: intercom.replying ? "Sending…" : "Send now"
                  tooltipText: "Ctrl+󰌑"
                  bordered: true
                  selected: true
                  enabled: !intercom.replying
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: root.sendReply()
                }

                Button {
                  id: sendLaterButton
                  text: "Send later..."
                  tooltipText: "Ctrl+S"
                  bordered: true
                  enabled: !intercom.replying
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: root.openScheduleDialog()
                }

                Item {
                  width: Math.max(0, parent.width
                    - sendNowButton.implicitWidth
                    - sendLaterButton.implicitWidth
                    - (discardDraftButton.visible ? discardDraftButton.implicitWidth + parent.spacing : 0)
                    - parent.spacing * (discardDraftButton.visible ? 3 : 2))
                  height: 1
                }

                Button {
                  id: discardDraftButton
                  visible: String(replyField.text || "").trim() !== ""
                    || Model.draftText(intercom.drafts, root.replyConversationId) !== ""
                  text: "Discard"
                  tooltipText: "Ctrl+Shift+D"
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: root.discardComposerDraft()
                }
              }

              Text {
                width: parent.width
                text: intercom.replying
                  ? "Sending…"
                  : "Ctrl+󰌑 send now  ·  Ctrl+S later  ·  Esc save draft  ·  Ctrl+Shift+D discard  ·  Ctrl+N note"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            LoadingMark {
              anchors.centerIn: parent
              visible: root.threadPaneLoading
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              label: "Loading messages…"
            }
          }
        }
      }
    }

    ScheduleDialog {
      id: scheduleDialog
      anchors.fill: parent
      foreground: root.foreground
      accent: root.accent
      urgent: root.urgent
      fontFamily: root.fontFamily
      monthFirst: root.localeMonthFirst
      weekStart: Qt.locale().firstDayOfWeek
      onCancelled: {
        Qt.callLater(function() {
          if (root.opened && root.composing && replyField) replyField.forceActiveFocus()
        })
      }
      onScheduled: function(sendAt) {
        root.commitScheduledReply(sendAt)
      }
    }

    NetworkPulse {
      id: networkPulse
      z: 50
      anchors.top: parent.top
      anchors.topMargin: -panel.padding + 2
      anchors.left: parent.left
      anchors.right: parent.right
      active: root.opened && intercom.networkActive
      accent: root.accent
    }

    ConfirmDialog {
      id: confirmDialog
      anchors.fill: parent
      opened: root.cancelConfirmOpen
      z: 40
      message: root.pendingCancelLabel !== ""
        ? "Discard the message scheduled for " + root.pendingCancelLabel + "?"
        : "Discard this scheduled message?"
      cancelText: "Keep"
      confirmText: "Discard"
      background: Color.popups.background
      foreground: root.foreground
      selectedText: root.accent
      fontFamily: root.fontFamily
      onCanceled: {
        root.closeConfirmDialog()
        Qt.callLater(function() {
          if (root.opened && !root.settingsOpen) keyCatcher.forceActiveFocus()
        })
      }
      onConfirmed: root.commitCancelScheduled()
    }
  }

  component ProfileIndicator: Row {
    id: chip

    property string adminName: ""
    property string adminEmail: ""
    property string adminId: ""
    property bool showInitials: true
    property bool busy: false
    property bool signingIn: false
    property bool focusable: false
    property color foreground: Color.foreground
    property color accent: Color.accent
    property string fontFamily: Style.font.family
    property Item signOutButton: null
    property Item signInButton: null

    readonly property bool hasProfile: Model.hasAdminProfile(adminName, adminEmail)
    readonly property string label: hasProfile
      ? Model.adminLabel(adminName, adminEmail, "")
      : "No teammate profile"
    readonly property string initials: Model.adminInitials(adminName, adminEmail)
    readonly property string emailLine: Model.adminEmailLine(adminName, adminEmail)

    signal signOutRequested()
    signal signInRequested()
    signal settingsKey(var event)

    spacing: Style.space(8)

    Rectangle {
      visible: chip.showInitials
      width: Style.space(28)
      height: Style.space(28)
      radius: width / 2
      anchors.verticalCenter: parent.verticalCenter
      color: Qt.rgba(chip.accent.r, chip.accent.g, chip.accent.b, 0.18)
      border.width: 1
      border.color: Qt.rgba(chip.accent.r, chip.accent.g, chip.accent.b, 0.45)

      Text {
        anchors.centerIn: parent
        text: chip.initials !== "" ? chip.initials : "󰀄"
        color: chip.accent
        font.family: chip.fontFamily
        font.pixelSize: chip.initials !== "" ? Style.font.caption : Style.font.bodySmall
        font.bold: true
      }
    }

    Column {
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        text: chip.label
        color: chip.foreground
        font.family: chip.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        elide: Text.ElideRight
        width: Math.min(implicitWidth, Style.space(180))
      }

      Row {
        spacing: Style.space(6)

        Text {
          visible: chip.emailLine !== ""
          anchors.verticalCenter: parent.verticalCenter
          text: chip.emailLine
          color: Qt.darker(chip.foreground, 1.5)
          font.family: chip.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: Math.min(implicitWidth, Style.space(140))
        }

        Button {
          id: signInLink
          visible: !chip.hasProfile
          anchors.verticalCenter: parent.verticalCenter
          text: chip.signingIn ? "Signing in…" : "Sign in again"
          bordered: false
          focusable: chip.focusable
          enabled: !chip.busy && !chip.signingIn
          tooltipText: "Grant Read admins on the Intercom app, then sign in again."
          foreground: chip.accent
          accent: chip.accent
          fontFamily: chip.fontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.space(4)
          verticalPadding: Style.space(2)
          Keys.onPressed: function(event) { chip.settingsKey(event) }
          onClicked: chip.signInRequested()
          Component.onCompleted: chip.signInButton = this
          Component.onDestruction: if (chip.signInButton === this) chip.signInButton = null
        }

        Button {
          id: signOutLink
          anchors.verticalCenter: parent.verticalCenter
          text: chip.busy ? "Signing out…" : "Sign out"
          bordered: false
          focusable: chip.focusable
          enabled: !chip.busy && !chip.signingIn
          foreground: chip.accent
          accent: chip.accent
          fontFamily: chip.fontFamily
          fontSize: Style.font.caption
          horizontalPadding: Style.space(4)
          verticalPadding: Style.space(2)
          Keys.onPressed: function(event) { chip.settingsKey(event) }
          onClicked: chip.signOutRequested()
          Component.onCompleted: chip.signOutButton = this
          Component.onDestruction: if (chip.signOutButton === this) chip.signOutButton = null
        }
      }
    }
  }

  component BarLoadingDots: Row {
    id: dots

    property color foreground: Color.foreground
    property real dotSize: Style.space(3)
    property bool running: visible

    spacing: Math.max(2, Math.round(dotSize * 0.75))

    Repeater {
      model: 3
      Rectangle {
        required property int index
        width: dots.dotSize
        height: dots.dotSize
        radius: width / 2
        color: dots.foreground
        opacity: 0.2

        SequentialAnimation on opacity {
          running: dots.running
          loops: Animation.Infinite
          PauseAnimation { duration: index * 160 }
          NumberAnimation { to: 1; duration: 220; easing.type: Easing.OutCubic }
          NumberAnimation { to: 0.2; duration: 280; easing.type: Easing.InCubic }
          PauseAnimation { duration: (2 - index) * 160 }
        }
      }
    }
  }

  component LoadingMark: Item {
    id: mark

    property color foreground: Color.foreground
    property color accent: Color.accent
    property string fontFamily: Style.font.family
    property string label: ""

    width: implicitWidth
    height: implicitHeight
    implicitWidth: Style.space(120)
    implicitHeight: stage.height + (caption.visible ? caption.implicitHeight + Style.space(14) : 0) + Style.space(18)

    Item {
      id: stage
      width: Style.space(88)
      height: Style.space(88)
      anchors.horizontalCenter: parent.horizontalCenter

      Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: "transparent"
        border.width: 1
        border.color: Qt.rgba(mark.accent.r, mark.accent.g, mark.accent.b, 0.18)
      }

      Rectangle {
        anchors.centerIn: parent
        width: Style.space(58)
        height: Style.space(58)
        radius: width / 2
        color: "transparent"
        border.width: 1
        border.color: Qt.rgba(mark.foreground.r, mark.foreground.g, mark.foreground.b, 0.10)
      }

      Item {
        anchors.fill: parent
        rotation: 0

        RotationAnimation on rotation {
          running: mark.visible
          from: 0
          to: 360
          duration: 2400
          loops: Animation.Infinite
        }

        Repeater {
          model: 3
          Item {
            required property int index
            anchors.fill: parent
            rotation: index * 120

            Rectangle {
              width: Style.space(8 - index)
              height: width
              radius: width / 2
              color: mark.accent
              opacity: 1 - index * 0.28
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.top: parent.top
              anchors.topMargin: -height / 2
            }
          }
        }
      }

      Item {
        anchors.centerIn: parent
        width: Style.space(58)
        height: Style.space(58)
        rotation: 0

        RotationAnimation on rotation {
          running: mark.visible
          from: 360
          to: 0
          duration: 3400
          loops: Animation.Infinite
        }

        Repeater {
          model: 2
          Item {
            required property int index
            anchors.fill: parent
            rotation: index * 180

            Rectangle {
              width: Style.space(5)
              height: width
              radius: width / 2
              color: mark.foreground
              opacity: 0.55
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.top: parent.top
              anchors.topMargin: -height / 2
            }
          }
        }
      }

      Text {
        id: glyph
        anchors.centerIn: parent
        text: "󰍡"
        color: mark.accent
        font.family: mark.fontFamily
        font.pixelSize: Style.font.display
        transformOrigin: Item.Center
        opacity: 0.55
        scale: 0.94

        SequentialAnimation on opacity {
          running: mark.visible
          loops: Animation.Infinite
          NumberAnimation { from: 0.4; to: 1; duration: 900; easing.type: Easing.InOutSine }
          NumberAnimation { from: 1; to: 0.4; duration: 900; easing.type: Easing.InOutSine }
        }

        SequentialAnimation on scale {
          running: mark.visible
          loops: Animation.Infinite
          NumberAnimation { from: 0.92; to: 1.06; duration: 900; easing.type: Easing.InOutSine }
          NumberAnimation { from: 1.06; to: 0.92; duration: 900; easing.type: Easing.InOutSine }
        }
      }
    }

    Text {
      id: caption
      visible: mark.label !== ""
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.top: stage.bottom
      anchors.topMargin: Style.space(14)
      text: mark.label
      color: Qt.darker(mark.foreground, 1.5)
      font.family: mark.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  component FilterChip: BorderSurface {
    id: chip

    property string label: ""
    property string countText: ""
    property string shortcut: ""
    property bool shortcutVisible: false
    property bool chosen: false
    property color foreground: Color.foreground
    property color accent: Color.accent
    property string fontFamily: Style.font.family

    signal activated()

    implicitWidth: chipLabel.implicitWidth + Style.space(16)
    implicitHeight: chipLabel.implicitHeight + Style.space(8)
    clip: false
    color: chosen ? Style.hoverFillFor(foreground, accent) : "transparent"
    borderSpec: chosen
      ? Border.controlSpec("normal", foreground, accent)
      : Border.flat(Qt.rgba(foreground.r, foreground.g, foreground.b, 0.13), 1)
    radius: Style.cornerRadius

    TapHandler {
      acceptedButtons: Qt.LeftButton
      onTapped: chip.activated()
    }

    Text {
      id: chipLabel
      anchors.centerIn: parent
      text: chip.label + (chip.countText !== "" ? "  " + chip.countText : "")
      color: chip.chosen ? chip.accent : chip.foreground
      font.family: chip.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: chip.chosen
    }

    BorderSurface {
      visible: chip.shortcutVisible && chip.shortcut !== ""
      z: 2
      enabled: false
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.topMargin: -Style.space(4)
      anchors.rightMargin: -Style.space(4)
      implicitWidth: Math.max(Style.space(18), shortcutLabel.implicitWidth + Style.space(8))
      implicitHeight: shortcutLabel.implicitHeight + Style.space(6)
      color: Qt.rgba(chip.accent.r, chip.accent.g, chip.accent.b, 0.16)
      borderSpec: Border.flat(Qt.rgba(chip.accent.r, chip.accent.g, chip.accent.b, 0.55), 1)
      radius: Style.cornerRadius

      Text {
        id: shortcutLabel
        anchors.centerIn: parent
        text: chip.shortcut
        color: chip.accent
        font.family: chip.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }
  }
}
