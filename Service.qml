import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root
  visible: false

  property var settings: ({})

  state: "loading"
  property string message: "Checking Intercom…"
  property bool countsLoaded: false
  property int waitingCount: 0
  property string inboxUrl: ""
  property string workspaceId: ""
  property string adminId: ""
  property string adminName: ""
  property string adminEmail: ""
  property var conversations: []
  property bool loading: false
  property bool refreshQueued: false
  property bool savingToken: false
  property bool signingIn: false
  property bool signingOut: false
  property bool replying: false
  property bool downloadingAttachment: false
  property string attachmentMessage: ""
  property string attachmentMessageConversationId: ""
  property bool closing: false
  property bool reopening: false
  property bool markingSpam: false
  property var blockedSenders: ({})
  property var blockedConversations: ({})
  property string replyMessage: ""
  property var openConversations: []
  property int openCount: 0
  property int closedCount: 0
  property int snoozedCount: 0
  property int allCount: 0
  // Only an inbox response can reveal the sidebar, not waiting previews.
  property string inboxLoadedSource: ""
  readonly property bool inboxLoaded: inboxLoadedSource === Model.inboxFetchFilter(inboxFilter)
  property bool openLoading: false
  property bool inboxQueued: false
  property string inboxQueuedSource: ""
  property string inboxQueuedCursor: ""
  property string inboxNextCursor: ""
  property string openMessage: ""
  property var messages: []
  property bool messagesLoading: false
  property string threadId: ""
  property string loadingThreadId: ""
  property string queuedThreadId: ""
  property bool queuedThreadForce: false
  property string threadMessage: ""
  property var thread: ({})
  property var threadCache: ({})
  property var inboxCache: ({})
  property var pendingInboxMoves: ({})
  property string inboxLiveSource: ""
  property bool cacheLoaded: false
  property bool liveFetchApplied: false
  property var prefetchQueue: []
  property string prefetchingId: ""
  property bool prefetchForce: false
  property double prefetchBatchAt: 0
  property double prefetchStartedAt: 0
  property string preferredPanel: "expanded"
  property bool panelLoaded: false
  property string inboxFilter: "open"
  property bool filterLoaded: false
  property string lastViewedId: ""
  property bool viewedLoaded: false
  property var pendingUrgent: ({})
  property var localReadState: ({})
  property bool initialReadSeeded: false
  property double initialReadBefore: 0
  property bool barUrgent: false
  property bool prefsQueued: false
  property var seenConversations: ({})
  property bool seenSeeded: false
  property var drafts: ({})
  property bool draftsLoaded: false
  property var scheduled: []
  property bool scheduledLoaded: false
  property bool syncing: false
  property string syncState: ""
  property string syncMessage: ""
  property int syncScanned: 0
  property int syncTotal: 0
  property var archiveIndex: ({})
  property bool searching: false
  property bool searchRemoteActive: false
  property string searchMessage: ""
  property var archiveSearchHits: []
  property string searchQueued: ""
  property bool searchQueuedRemote: false

  signal tokenSaved()
  signal signedOut()
  signal replySent(string conversationId)
  signal conversationClosed(string conversationId)
  signal conversationReopened(string conversationId)
  signal senderMarkedSpam(string conversationId)
  signal newWaitingMessages(var conversations)

  readonly property string pluginRoot: resolvedPluginRoot()
  readonly property string draftsDir: resolvedDraftsDir()
  readonly property string draftsPath: draftsDir === "" ? "" : draftsDir + "/drafts.json"
  readonly property string scheduledPath: draftsDir === "" ? "" : draftsDir + "/scheduled.json"
  readonly property string cachePath: draftsDir === "" ? "" : draftsDir + "/cache.json"
  readonly property string configPath: draftsDir === "" ? "" : draftsDir + "/config.json"
  readonly property string archiveDir: draftsDir === "" ? "" : draftsDir + "/archive"
  readonly property string syncStatusPath: archiveDir === "" ? "" : archiveDir + "/status.json"
  readonly property string archiveIndexPath: archiveDir === "" ? "" : archiveDir + "/index.json"
  readonly property int refreshIntervalMs: intSetting("refreshIntervalSec", 60, 15, 3600) * 1000
  readonly property string tokenFile: String(setting("tokenFile", "")).trim()
  readonly property bool networkActive: loading || openLoading || messagesLoading
    || prefetchProcess.running || replying || downloadingAttachment || closing || reopening || markingSpam
    || (searching && searchRemoteActive) || syncing
    || signingIn || signingOut || savingToken

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, minimum, maximum) {
    var value = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(value)) value = fallback
    return Math.max(minimum, Math.min(maximum, value))
  }

  function urlToPath(value) {
    var text = String(value || "")
    if (text.indexOf("file://") === 0) text = text.slice(7)
    try { return decodeURIComponent(text) } catch (error) { return text }
  }

  function resolvedPluginRoot() {
    var manifestPath = urlToPath(Qt.resolvedUrl("manifest.json"))
    var slash = manifestPath.lastIndexOf("/")
    return slash >= 0 ? manifestPath.slice(0, slash) : "."
  }

  function resolvedDraftsDir() {
    var xdg = String(Quickshell.env("XDG_CONFIG_HOME") || "").trim()
    var home = String(Quickshell.env("HOME") || "").trim()
    var base = xdg !== "" ? xdg : (home !== "" ? home + "/.config" : "")
    if (base === "") return ""
    return base + "/omarchy/omarchy-intercom-client"
  }

  function fetchCommand() {
    return withTokenFile([root.pluginRoot + "/intercom-fetch", "--limit", "150"])
  }

  function inboxCommand(source, cursor) {
    var mode = Model.inboxFetchFilter(source || inboxFilter)
    var command = [
      root.pluginRoot + "/intercom-fetch",
      "--inbox",
      mode,
      "--limit",
      "150"
    ]
    // Historical views can contain years of conversations. Fetch them on demand,
    // while active inboxes stay complete for unread reconciliation and counts.
    if (mode === "closed" || mode === "all") command.push("--page")
    if (String(cursor || "") !== "") command.push("--starting-after", String(cursor))
    return withTokenFile(command)
  }

  function threadCommand(conversationId) {
    return withTokenFile([root.pluginRoot + "/intercom-fetch", "--conversation", String(conversationId || "")])
  }

  function withTokenFile(command) {
    if (root.tokenFile !== "") {
      command.push("--token-file")
      command.push(root.tokenFile)
    }
    return command
  }

  function refresh() {
    sendDueScheduled()
    if (fetchProcess.running) {
      refreshQueued = true
      return
    }
    refreshQueued = false
    loading = true
    _stdout = ""
    _stderr = ""
    fetchProcess.command = fetchCommand()
    fetchProcess.running = true
    watchdog.restart()
  }

  function refreshNow(conversationId) {
    refresh()
    loadInbox()
    var id = String(conversationId || "").trim()
    if (id !== "")
      loadThread(id, true)
  }

  function applyOutput(raw, exitCode) {
    var parsed = Model.parseFetch(raw)
    if (exitCode !== 0 && parsed.state === "error" && parsed.message === "Could not parse Intercom response.") {
      var stderr = String(_stderr || "").replace(/\s+/g, " ").trim()
      parsed.message = stderr === "" ? "Could not refresh Intercom." : stderr
    }
    if (parsed.state === "unconfigured") {
      applyUnconfigured(parsed)
      return
    }
    if (parsed.state !== "ready") {
      state = parsed.state
      message = parsed.message
      if (!countsLoaded) countsLoaded = true
      return
    }
    liveFetchApplied = true
    state = parsed.state
    message = parsed.message
    countsLoaded = true
    waitingCount = parsed.waitingCount
    if (parsed.hasInboxCounts) {
      openCount = parsed.openCount
      closedCount = parsed.closedCount
      snoozedCount = parsed.snoozedCount
      allCount = parsed.allCount
    }
    inboxUrl = parsed.inboxUrl
    workspaceId = parsed.workspaceId
    adminId = parsed.adminId
    adminName = parsed.adminName
    adminEmail = parsed.adminEmail
    applyPrefs(parsed)
    parsed.conversations = withoutSpam(parsed.conversations)
    conversations = parsed.conversations
    if (state === "ready" && waitingCount === 0)
      message = "No conversations are waiting for a reply."
    seedThreadCache(parsed.conversations)
    notifyNewMessages(parsed)
    if (!inboxLoaded && !openLoading)
      loadInbox()
    if (!initialReadSeeded && Model.inboxFetchFilter(inboxFilter) !== "open")
      loadInbox("open")
    schedulePersistCache()
  }

  function applyUnconfigured(parsed) {
    var row = parsed || {}
    clearSession()
    if (String(row.message || "") !== "")
      message = String(row.message)
  }

  function notifyNewMessages(parsed) {
    var row = parsed || {}
    if (row.state !== "ready") return
    var current = row.conversations
    if (!seenSeeded) {
      seenConversations = Model.conversationIndex(current)
      seenSeeded = true
      return
    }
    var news = Model.newMessageConversations(seenConversations, current)
    var toNotify = Model.notificationsToSend(seenConversations, current, Model.notificationLimit())
    seenConversations = Model.conversationIndex(current)
    if (news.length) {
      threadCache = Model.expireCachedThreads(threadCache, news)
      schedulePersistCache()
      var currentId = String(threadId || "")
      if (Model.findConversationById(news, currentId))
        loadThread(currentId, true)
      loadInbox()
      prefetchThreads(news, currentId, true)
      root.newWaitingMessages(news)
    }
    for (var i = 0; i < toNotify.length; i++)
      sendMessageNotification(toNotify[i])
  }

  function sendMessageNotification(conversation) {
    var command = Model.notificationCommand(conversation)
    if (!command || command.length === 0) return
    Quickshell.execDetached(command)
  }

  function applyPrefs(parsed) {
    var row = parsed || {}
    var filterJustLoaded = !filterLoaded
    applyLoadedPrefs(row.panel, row.filter, row.viewed)
    if (filterJustLoaded && Model.inboxFetchFilter(inboxFilter) !== "open")
      loadInbox()
  }

  function applyLocalPrefs(raw) {
    var prefs = Model.parsePrefs(raw)
    applyLoadedPrefs(prefs.panel, prefs.filter, prefs.viewed)
  }

  function applyLoadedPrefs(panel, filter, viewed) {
    var filterJustLoaded = !filterLoaded
    if (!viewedLoaded) {
      var viewedId = String(viewed || "")
      if (Model.isSafeConversationId(viewedId)) lastViewedId = viewedId
      viewedLoaded = true
    }
    if (!filterLoaded) {
      inboxFilter = Model.inboxFilterMode(filter)
      filterLoaded = true
    }
    if (!panelLoaded) {
      preferredPanel = Model.panelMode(panel)
      panelLoaded = true
    }
    if (filterJustLoaded && !liveFetchApplied)
      showCachedInbox()
  }

  function applyIdentity(parsed) {
    var row = parsed || {}
    if (String(row.adminId || "") !== "") adminId = String(row.adminId)
    if (String(row.adminName || "") !== "") adminName = String(row.adminName)
    if (String(row.adminEmail || "") !== "") adminEmail = String(row.adminEmail)
  }

  function savePanel(mode) {
    preferredPanel = Model.panelMode(mode)
    panelLoaded = true
    savePrefs()
  }

  function saveFilter(filter) {
    var mode = Model.inboxFilterMode(filter)
    var previousSource = Model.inboxFetchFilter(inboxFilter)
    inboxFilter = mode
    filterLoaded = true
    savePrefs()
    if (Model.inboxFetchFilter(mode) !== previousSource)
      loadInbox()
  }

  function saveViewed(conversationId) {
    var id = String(conversationId || "").trim()
    if (!Model.isSafeConversationId(id)) return
    lastViewedId = id
    viewedLoaded = true
    savePrefs()
  }

  function observeMessages(conversation, read) {
    var id = String((conversation || {}).id || "")
    var previous = (localReadState || {})[id] || {}
    // The first complete Open inbox establishes the baseline, not an unread backlog.
    var next = Model.updateLocalReadState(
      localReadState, conversation, !!read || !initialReadSeeded, adminEmail, initialReadBefore
    )
    var observed = next[id] || {}
    var hasNew = false
    for (var key in observed) {
      if (observed[key] === false && !Object.prototype.hasOwnProperty.call(previous, key)) hasNew = true
    }
    localReadState = next
    pendingUrgent = Model.localUnreadConversations(localReadState)
    refreshBarUrgent()
    schedulePersistCache()
    return hasNew
  }

  function markConversationRead(conversationId) {
    var id = String(conversationId || "")
    if (!Model.isSafeConversationId(id) || !pendingUrgent[id]) return
    localReadState = Model.markConversationRead(localReadState, id)
    pendingUrgent = Model.localUnreadConversations(localReadState)
    refreshBarUrgent()
    schedulePersistCache()
  }

  function refreshBarUrgent() {
    barUrgent = Model.pendingUrgentCount(pendingUrgent) > 0
  }

  function draftText(conversationId) {
    return Model.draftText(drafts, conversationId)
  }

  function saveDraft(conversationId, text, note, attachments) {
    var next = Model.setDraft(drafts, conversationId, text, note, attachments)
    drafts = next
    draftsLoaded = true
    persistDrafts()
  }

  function discardDraft(conversationId) {
    saveDraft(conversationId, "")
  }

  function persistDrafts() {
    if (!draftsLoaded || draftsPath === "") return
    draftsFile.setText(JSON.stringify(drafts) + "\n")
  }

  function applyDrafts(raw) {
    if (draftsLoaded) return
    drafts = Model.parseDrafts(raw)
    draftsLoaded = true
  }

  function persistScheduled() {
    if (!scheduledLoaded || scheduledPath === "") return
    scheduledFile.setText(JSON.stringify(scheduled) + "\n")
  }

  function applyScheduled(raw) {
    if (scheduledLoaded) return
    scheduled = Model.parseScheduled(raw)
    scheduledLoaded = true
    Qt.callLater(root.sendDueScheduled)
  }

  function scheduleReply(conversationId, markdown, asNote, sendAt, attachments) {
    var id = String(conversationId || "").trim()
    var body = String(markdown || "")
    var at = Number(sendAt)
    if (!Model.isSafeConversationId(id)) {
      replyMessage = "Select a conversation first."
      return false
    }
    if (body.trim() === "" && !Model.localAttachments(attachments).length) {
      replyMessage = "Write a message or attach a file before sending."
      return false
    }
    if (!isFinite(at) || at <= Date.now()) {
      replyMessage = "Choose a time in the future."
      return false
    }
    scheduled = Model.addScheduled(scheduled, id, body, !!asNote, at, Date.now(), attachments)
    scheduledLoaded = true
    persistScheduled()
    replyMessage = ""
    return true
  }

  function cancelScheduled(scheduledId) {
    scheduled = Model.removeScheduled(scheduled, scheduledId)
    persistScheduled()
  }

  function sendDueScheduled() {
    if (!scheduledLoaded || replying || replyProcess.running || markingSpam) return
    if (state === "unconfigured") return
    var due = Model.dueScheduled(scheduled, Date.now())
    if (due.length === 0) return
    var item = due[0]
    _sendingScheduledId = String(item.id || "")
    reply(item.conversationId, item.body, item.note, item.attachments)
    if (!replying) _sendingScheduledId = ""
  }

  function inboxCountForSource(source) {
    if (source === "closed") return closedCount
    if (source === "snoozed") return snoozedCount
    if (source === "all") return allCount
    return openCount
  }

  function rememberInbox(source, conversations, count, nextCursor) {
    var cursor = nextCursor !== undefined ? nextCursor : Model.readInboxCache(inboxCache, source).nextCursor
    inboxCache = Model.writeInboxCache(inboxCache, source, conversations, count, Date.now(), cursor)
  }

  function showCachedInbox() {
    var source = Model.inboxFetchFilter(inboxFilter)
    if (inboxLiveSource === source && inboxLoaded) return true
    var snap = Model.readInboxCache(inboxCache, source)
    var conversations = Model.applyPendingInboxMoves(
      snap.conversations,
      source,
      pendingInboxMoves,
      Date.now()
    )
    if (!snap || (snap.fetchedAt <= 0 && conversations.length === 0)) return false
    applyInboxCount(source, snap.count)
    openConversations = conversations
    inboxNextCursor = snap.nextCursor
    if (source === "open" && openCount < conversations.length)
      openCount = conversations.length
    seedThreadCache(conversations)
    inboxLoadedSource = source
    return true
  }

  function applyInboxCount(source, count) {
    var value = Math.max(0, Math.floor(Number(count) || 0))
    if (source === "open")
      openCount = value
    else if (source === "closed")
      closedCount = value
    else if (source === "snoozed")
      snoozedCount = value
    else if (source === "all")
      allCount = value
  }

  function cacheSnapshot() {
    return {
      ready: true,
      fetchedAt: Date.now(),
      state: "ready",
      message: message,
      waitingCount: waitingCount,
      openCount: openCount,
      closedCount: closedCount,
      snoozedCount: snoozedCount,
      allCount: allCount,
      inboxUrl: inboxUrl,
      workspaceId: workspaceId,
      adminId: adminId,
      adminName: adminName,
      adminEmail: adminEmail,
      conversations: conversations,
      inboxes: inboxCache,
      threads: threadCache,
      initialReadBefore: initialReadBefore,
      localReadState: localReadState
    }
  }

  function schedulePersistCache() {
    if (!cacheLoaded || cachePath === "") return
    cachePersistTimer.restart()
  }

  function persistCacheNow() {
    cachePersistTimer.stop()
    if (!cacheLoaded || cachePath === "") return
    if (state === "unconfigured") {
      cacheFile.setText(Model.serializeDiskCache(Model.emptyDiskCache()) + "\n")
      return
    }
    if (state !== "ready") return
    cacheFile.setText(Model.serializeDiskCache(cacheSnapshot()) + "\n")
  }

  function startBackgroundRefresh() {
    if (refreshTimer.running) return
    refreshTimer.running = true
  }

  function applyDiskCache(raw) {
    if (cacheLoaded) {
      startBackgroundRefresh()
      return
    }
    cacheLoaded = true
    if (state === "unconfigured") {
      persistCacheNow()
      startBackgroundRefresh()
      return
    }
    var snapshot = Model.parseDiskCache(raw)
    if (!liveFetchApplied && snapshot.ready)
      restoreDiskCache(snapshot)
    startBackgroundRefresh()
  }

  function restoreDiskCache(snapshot) {
    var row = snapshot || {}
    countsLoaded = true
    state = "ready"
    message = String(row.message || "")
    waitingCount = row.waitingCount
    if (row.hasInboxCounts) {
      openCount = row.openCount
      closedCount = row.closedCount
      snoozedCount = row.snoozedCount
      allCount = row.allCount
    }
    if (String(row.inboxUrl || "") !== "") inboxUrl = String(row.inboxUrl)
    if (String(row.workspaceId || "") !== "") workspaceId = String(row.workspaceId)
    if (String(row.adminId || "") !== "") adminId = String(row.adminId)
    if (String(row.adminName || "") !== "") adminName = String(row.adminName)
    if (String(row.adminEmail || "") !== "") adminEmail = String(row.adminEmail)
    conversations = row.conversations || []
    if (waitingCount === 0)
      message = "No conversations are waiting for a reply."
    threadCache = row.threads || {}
    inboxCache = row.inboxes || {}
    var openSnapshot = Model.readInboxCache(inboxCache, "open")
    initialReadSeeded = openSnapshot.fetchedAt > 0 || openSnapshot.conversations.length > 0
    initialReadBefore = row.initialReadBefore || 0
    localReadState = Model.restoreLocalReadState(row)
    pendingUrgent = Model.localUnreadConversations(localReadState)
    refreshBarUrgent()
    seenConversations = Model.conversationIndex(conversations)
    seenSeeded = true
    showCachedInbox()
    seedThreadCache(conversations)
  }

  function savePrefs() {
    if (panelProcess.running) {
      prefsQueued = true
      return
    }
    prefsQueued = false
    var command = withTokenFile([
      root.pluginRoot + "/intercom-fetch",
      "--panel",
      Model.panelMode(preferredPanel),
      "--filter",
      Model.inboxFilterMode(inboxFilter)
    ])
    if (Model.isSafeConversationId(lastViewedId)) {
      command.push("--viewed")
      command.push(lastViewedId)
    }
    panelProcess.command = command
    panelProcess.running = true
  }

  function loadMoreInbox() {
    if (openLoading || inboxNextCursor === "") return
    loadInbox(undefined, inboxNextCursor)
  }

  function pumpInboxQueue() {
    if (!inboxQueued || _inboxInFlight) return
    var source = inboxQueuedSource
    var cursor = inboxQueuedCursor
    inboxQueued = false
    inboxQueuedSource = ""
    inboxQueuedCursor = ""
    loadInbox(source, cursor)
  }

  function loadInbox(source, cursor) {
    var wanted = source !== undefined && source !== null && String(source) !== ""
      ? Model.inboxFetchFilter(source)
      : Model.inboxFetchFilter(inboxFilter)
    var viewing = wanted === Model.inboxFetchFilter(inboxFilter)
    var after = String(cursor || "")
    var inFlight = _inboxInFlight || inboxProcess.running
    if (inFlight && !_inboxCancelled && _inboxRequested === wanted && _inboxCursor === after) return
    // A background baseline refresh must not displace the user's queued tab.
    if (!viewing && inboxQueued && inboxQueuedSource === Model.inboxFetchFilter(inboxFilter)) return
    if (viewing) {
      if (!showCachedInbox() && !inboxLoaded) {
        openConversations = []
        inboxNextCursor = ""
      }
      openLoading = true
      openMessage = ""
    }
    if (inFlight) {
      inboxQueued = true
      inboxQueuedSource = wanted
      inboxQueuedCursor = after
      if (viewing && wanted !== _inboxRequested && !_inboxCancelled) {
        _inboxCancelled = true
        inboxWatchdog.stop()
        inboxProcess.running = false
      }
      return
    }
    inboxQueued = false
    inboxQueuedSource = ""
    inboxQueuedCursor = ""
    _inboxRequested = wanted
    _inboxCursor = after
    _inboxTimedOut = false
    _inboxCancelled = false
    _inboxInFlight = true
    _inboxStdout = ""
    _inboxStderr = ""
    inboxProcess.command = inboxCommand(wanted, after)
    inboxProcess.running = true
    inboxWatchdog.restart()
  }

  function applyInbox(raw, exitCode) {
    var parsed = Model.parseFetch(raw)
    if (_inboxTimedOut) {
      parsed = Model.emptyFetch("error", "Loading conversations timed out. Press r to retry or choose another tab.")
    }
    if (exitCode !== 0 && parsed.state === "error" && parsed.message === "Could not parse Intercom response.") {
      var stderr = String(_inboxStderr || "").replace(/\s+/g, " ").trim()
      parsed.message = stderr === "" ? "Could not load conversations." : stderr
    }
    if (parsed.inboxUrl !== "") inboxUrl = parsed.inboxUrl
    if (parsed.workspaceId !== "") workspaceId = parsed.workspaceId
    if (parsed.adminId !== "") adminId = parsed.adminId
    if (parsed.adminName !== "") adminName = parsed.adminName
    if (parsed.adminEmail !== "") adminEmail = parsed.adminEmail
    applyPrefs(parsed)
    var source = String(_inboxRequested || "open")
    if (parsed.state === "unconfigured") {
      applyUnconfigured(parsed)
      return
    }
    if (parsed.state !== "ready") {
      if (source === Model.inboxFetchFilter(inboxFilter))
        openMessage = parsed.message
      return
    }
    var count = parsed.inboxCount > 0
      ? parsed.inboxCount
      : (parsed.openCount > 0 ? parsed.openCount : parsed.conversations.length)
    var previous = Model.readInboxCache(inboxCache, source)
    var rows = _inboxCursor === "" ? parsed.conversations
      : Model.mergeConversationPages(previous.conversations, parsed.conversations)
    var merged = Model.applyPendingInboxMoves(
      withoutSpam(rows),
      source,
      pendingInboxMoves,
      Date.now()
    )
    if (!Model.hasPendingInboxMoves(pendingInboxMoves, Date.now())) {
      applyInboxCount(source, source === "open"
        ? (parsed.openCount > 0 ? parsed.openCount : parsed.conversations.length)
        : count)
    }
    rememberInbox(source, merged, inboxCountForSource(source), parsed.nextCursor)
    if (source === "open") {
      localReadState = Model.reconcileOpenReadState(localReadState, merged)
      pendingUrgent = Model.localUnreadConversations(localReadState)
      refreshBarUrgent()
    }
    seedThreadCache(merged)
    if (source === "open" && !initialReadSeeded) {
      initialReadBefore = Math.floor(Date.now() / 1000)
      initialReadSeeded = true
    }
    if (source !== Model.inboxFetchFilter(inboxFilter)) {
      schedulePersistCache()
      return
    }
    liveFetchApplied = true
    inboxLiveSource = source
    openConversations = merged
    inboxNextCursor = parsed.nextCursor
    if (source === "open" && openCount < merged.length)
      openCount = merged.length
    openMessage = ""
    inboxLoadedSource = source
    schedulePersistCache()
  }

  function cachedThread(conversationId) {
    return Model.readCachedThread(threadCache, conversationId)
  }

  function seedThreadCache(conversations) {
    var list = withoutSpam(conversations)
    var now = Date.now()
    var cache = threadCache
    var currentId = String(threadId || "")
    var shown = null
    var refreshCurrent = false
    for (var i = 0; i < list.length; i++) {
      var conv = list[i] || {}
      if (String(conv.id || "") === "") continue
      var hasNew = observeMessages(conv, false)
      var existing = Model.readCachedThread(cache, conv.id)
      if (existing && String(conv.state || "") !== "" && existing.conversation.state !== conv.state) {
        existing.conversation.state = conv.state
        cache = Model.writeCachedThread(cache, existing.conversation, existing.fetchedAt, existing.complete)
      }
      if (String(conv.state || "") !== "" && String(conv.id) === currentId
          && String((thread || {}).id || "") === currentId && thread.state !== conv.state) {
        var updated = Model.copyConversation(thread)
        updated.state = conv.state
        thread = updated
      }
      if (!(conv.messages || []).length) continue
      if (existing && existing.complete && !hasNew) continue
      if (hasNew && String(conv.id) === currentId) refreshCurrent = true
      cache = Model.writeCachedThread(cache, conv, now, false)
      if (!shown && String(conv.id) === currentId && messages.length === 0 && String(loadingThreadId || "") !== currentId)
        shown = conv
    }
    threadCache = cache
    if (shown)
      showThread(shown)
    // Follow-ups can arrive without changing Intercom's waiting timestamp.
    if (refreshCurrent)
      Qt.callLater(function() {
        if (String(root.threadId || "") === currentId) root.loadThread(currentId, true)
      })
  }

  function showThread(conv) {
    var row = conv || {}
    observeMessages(row, false)
    var source = row.messages || []
    var copy = []
    for (var i = 0; i < source.length; i++)
      copy.push(source[i])
    thread = row
    messages = copy
    if (copy.length === 0)
      threadMessage = "No messages in this conversation."
    else
      threadMessage = ""
  }

  function loadThread(conversationId, force) {
    var id = String(conversationId || "").trim()
    if (blockedConversations[id]) return
    var refresh = !!force
    if (id === "") {
      threadId = ""
      queuedThreadId = ""
      queuedThreadForce = false
      messages = []
      thread = {}
      threadMessage = ""
      messagesLoading = false
      return
    }

    var switching = String(threadId || "") !== id
    threadId = id
    var entry = cachedThread(id)
    var cachedConv = entry ? entry.conversation : null
    if (cachedConv) {
      if (switching || messages.length === 0)
        showThread(cachedConv)
    } else if (switching) {
      messages = []
      thread = {}
      threadMessage = ""
    }

    if (!refresh && Model.cachedThreadFresh(entry, Date.now(), Model.threadCacheTtlMs())) {
      queuedThreadId = ""
      queuedThreadForce = false
      messagesLoading = String(loadingThreadId || "") === id || String(prefetchingId || "") === id
      return
    }

    if (prefetchProcess.running && String(prefetchingId || "") === id && !refresh) {
      messagesLoading = !cachedConv
      return
    }

    if (threadProcess.running) {
      var next = Model.queuedThreadAfterInFlight(
        loadingThreadId, queuedThreadId, queuedThreadForce, id, refresh
      )
      queuedThreadId = next.id
      queuedThreadForce = next.force
      messagesLoading = true
      return
    }

    queuedThreadId = ""
    queuedThreadForce = false
    loadingThreadId = id
    messagesLoading = true
    if (!cachedConv)
      threadMessage = ""
    _threadStdout = ""
    _threadStderr = ""
    threadProcess.command = threadCommand(id)
    threadProcess.running = true
    threadWatchdog.restart()
  }

  function applyThread(raw, exitCode) {
    var parsed = Model.parseFetch(raw)
    var conv = parsed.conversation || {}
    var fetchedId = String(loadingThreadId || conv.id || "")
    var queued = String(queuedThreadId || "")
    var queuedForce = queuedThreadForce
    var currentId = String(threadId || "")
    if (exitCode !== 0 && parsed.state === "error" && parsed.message === "Could not parse Intercom response.") {
      var stderr = String(_threadStderr || "").replace(/\s+/g, " ").trim()
      parsed.message = stderr === "" ? "Could not load conversation." : stderr
    }
    applyIdentity(parsed)
    var failed = parsed.state === "error" || parsed.state === "unconfigured"
    if (Model.conversationIsSpam({ id: fetchedId, senderId: conv.senderId }, blockedSenders, blockedConversations)) {
      conv = {}
      failed = true
    }
    var convId = String(conv.id || "")
    if (!failed && convId !== "") {
      observeMessages(conv, false)
      threadCache = Model.writeCachedThread(threadCache, conv, Date.now())
      schedulePersistCache()
      fetchedId = convId
    }
    loadingThreadId = ""
    if (fetchedId !== "" && fetchedId === currentId) {
      if (failed) {
        if (!cachedThread(currentId)) {
          thread = conv
          messages = conv.messages || []
        }
        threadMessage = parsed.message
      } else {
        showThread(conv)
      }
    }
    if (queued !== "") {
      queuedThreadId = ""
      queuedThreadForce = false
      Qt.callLater(function() { root.loadThread(queued, queuedForce) })
      return
    }
    messagesLoading = String(prefetchingId || "") === currentId
  }

  function prefetchThreads(conversations, priorityId, force) {
    if (force) {
      prefetchForce = true
      prefetchBatchAt = Date.now()
    }
    prefetchQueue = Model.prefetchThreadIds(
      conversations,
      priorityId,
      threadCache,
      Date.now(),
      Model.threadCacheTtlMs(),
      prefetchForce
    )
    if (prefetchProcess.running) return
    if (prefetchTimer.running && !force) return
    prefetchTimer.stop()
    pumpPrefetch()
  }

  function stopPrefetch() {
    prefetchQueue = []
    prefetchForce = false
    prefetchBatchAt = 0
    prefetchTimer.stop()
  }

  function takeNextPrefetchId() {
    var now = Date.now()
    var remaining = []
    var chosen = ""
    for (var i = 0; i < prefetchQueue.length; i++) {
      var id = String(prefetchQueue[i] || "")
      if (id === "") continue
      if (id === String(loadingThreadId || "") || id === String(prefetchingId || "") || id === String(queuedThreadId || ""))
        continue
      var entry = cachedThread(id)
      if (prefetchForce) {
        if (entry && entry.fetchedAt >= prefetchBatchAt)
          continue
      } else if (Model.cachedThreadFresh(entry, now, Model.threadCacheTtlMs())) {
        continue
      }
      if (chosen === "")
        chosen = id
      else
        remaining.push(id)
    }
    prefetchQueue = remaining
    if (chosen === "" && remaining.length === 0)
      prefetchForce = false
    return chosen
  }

  function pumpPrefetch() {
    if (prefetchProcess.running) return
    var id = takeNextPrefetchId()
    if (id === "") return
    prefetchingId = id
    prefetchStartedAt = Date.now()
    _prefetchStdout = ""
    _prefetchStderr = ""
    prefetchProcess.command = threadCommand(id)
    prefetchProcess.running = true
    prefetchWatchdog.restart()
  }

  function schedulePrefetch() {
    if (prefetchQueue.length === 0) return
    prefetchTimer.restart()
  }

  function applyPrefetch(raw, exitCode) {
    var parsed = Model.parseFetch(raw)
    var conv = parsed.conversation || {}
    var fetchedId = String(prefetchingId || conv.id || "")
    var currentId = String(threadId || "")
    if (exitCode !== 0 && parsed.state === "error" && parsed.message === "Could not parse Intercom response.") {
      var stderr = String(_prefetchStderr || "").replace(/\s+/g, " ").trim()
      parsed.message = stderr === "" ? "Could not load conversation." : stderr
    }
    var failed = parsed.state === "error" || parsed.state === "unconfigured"
    if (Model.conversationIsSpam({ id: fetchedId, senderId: conv.senderId }, blockedSenders, blockedConversations)) {
      conv = {}
      failed = true
    }
    var convId = String(conv.id || "")
    var existing = convId !== "" ? cachedThread(convId) : null
    var stale = Model.prefetchResultStale(existing, prefetchStartedAt)
    if (!failed && convId !== "" && !stale) {
      observeMessages(conv, false)
      threadCache = Model.writeCachedThread(threadCache, conv, Date.now())
      schedulePersistCache()
      fetchedId = convId
    }
    prefetchingId = ""
    if (!stale && fetchedId !== "" && fetchedId === currentId && String(loadingThreadId || "") !== currentId) {
      if (failed) {
        if (!cachedThread(currentId)) {
          thread = conv
          messages = conv.messages || []
        }
        threadMessage = parsed.message
      } else {
        showThread(conv)
      }
      if (!threadProcess.running)
        messagesLoading = false
    }
  }

  function openUrl(url) {
    var target = String(url || "").trim()
    if (!Model.isSafeHttpUrl(target)) return
    Quickshell.execDetached(["omarchy-launch-browser", target])
  }

  function openConversation(conversation) {
    var row = conversation || {}
    var target = String(row.url || "").trim()
    if (target === "") {
      if (state === "ready")
        message = "Paste an Intercom inbox URL so conversation links can open."
      return
    }
    openUrl(target)
  }

  function openInbox() {
    openUrl(inboxUrl)
  }

  function setAttachmentMessage(text, conversationId) {
    attachmentMessageConversationId = String(conversationId || "")
    attachmentMessage = String(text || "")
  }

  function clearAttachmentMessage() {
    setAttachmentMessage("", "")
  }

  function downloadAttachment(attachment, destination, conversationId) {
    if (downloadProcess.running) return
    var url = Model.safeImageUrl((attachment || {}).url)
    if (url === "") return
    downloadingAttachment = true
    _downloadConversationId = String(conversationId || threadId || "")
    setAttachmentMessage("Downloading attachment…", _downloadConversationId)
    _downloadSecret = JSON.stringify({ url: url, path: String(destination || "") })
    downloadProcess.command = [root.pluginRoot + "/intercom-fetch", "--download-attachment"]
    downloadProcess.running = true
    downloadWatchdog.restart()
  }

  function saveToken(token, workspace) {
    var value = String(token || "").replace(/\s+/g, "").trim()
    var workspaceId = String(workspace || "").replace(/\s+/g, "").trim()
    if (value === "" && workspaceId === "") {
      if (state === "ready" || state === "loading") state = "unconfigured"
      message = "Paste an Intercom access token first."
      return
    }
    if (saveProcess.running) return
    savingToken = true
    message = "Saving…"
    _saveStdout = ""
    _saveStderr = ""
    _saveSecret = value
    var command = [root.pluginRoot + "/intercom-fetch"]
    if (value !== "") command.push("--save-token")
    if (root.tokenFile !== "") {
      command.push("--token-file")
      command.push(root.tokenFile)
    }
    if (workspaceId !== "") {
      command.push("--workspace")
      command.push(workspaceId)
    }
    saveProcess.command = command
    saveProcess.running = true
  }

  function login(clientId, clientSecret) {
    if (loginProcess.running) return
    var id = String(clientId || "").replace(/\s+/g, "").trim()
    var secret = String(clientSecret || "").replace(/\s+/g, "").trim()
    signingIn = true
    message = "Waiting for Intercom sign-in in the browser…"
    _loginStdout = ""
    _loginStderr = ""
    _loginSecret = ""
    var command = [root.pluginRoot + "/intercom-fetch"]
    if (id !== "" || secret !== "") {
      command.push("--save-oauth")
      _loginSecret = JSON.stringify({ clientId: id, clientSecret: secret })
    }
    command.push("--login")
    if (root.tokenFile !== "") {
      command.push("--token-file")
      command.push(root.tokenFile)
    }
    loginProcess.command = command
    loginProcess.running = true
    loginWatchdog.restart()
  }

  function clearSession() {
    stopPrefetch()
    state = "unconfigured"
    message = "Sign in with Intercom to connect this plugin."
    countsLoaded = true
    waitingCount = 0
    inboxUrl = ""
    adminId = ""
    adminName = ""
    adminEmail = ""
    conversations = []
    openConversations = []
    openCount = 0
    closedCount = 0
    snoozedCount = 0
    allCount = 0
    inboxLoadedSource = ""
    openLoading = false
    inboxQueued = false
    inboxQueuedSource = ""
    inboxQueuedCursor = ""
    inboxNextCursor = ""
    openMessage = ""
    messages = []
    messagesLoading = false
    threadId = ""
    loadingThreadId = ""
    queuedThreadId = ""
    queuedThreadForce = false
    threadMessage = ""
    thread = {}
    threadCache = {}
    inboxCache = {}
    pendingInboxMoves = ({})
    inboxLiveSource = ""
    prefetchQueue = []
    prefetchingId = ""
    seenConversations = {}
    seenSeeded = false
    pendingUrgent = ({})
    localReadState = ({})
    initialReadSeeded = false
    initialReadBefore = 0
    barUrgent = false
    replyMessage = ""
    clearAttachmentMessage()
    closing = false
    reopening = false
    markingSpam = false
    blockedSenders = ({})
    blockedConversations = ({})
    syncing = false
    searching = false
    searchMessage = ""
    archiveSearchHits = []
    persistCacheNow()
  }

  function signOut() {
    if (logoutProcess.running || signingIn) return
    signingOut = true
    _logoutStdout = ""
    _logoutStderr = ""
    logoutProcess.command = withTokenFile([root.pluginRoot + "/intercom-fetch", "--logout"])
    logoutProcess.running = true
  }

  function reply(conversationId, markdown, asNote, attachments) {
    var id = String(conversationId || "").trim()
    var body = String(markdown || "")
    if (!Model.isSafeConversationId(id)) {
      replyMessage = "Select a conversation first."
      return
    }
    if (body.trim() === "" && !Model.localAttachments(attachments).length) {
      replyMessage = "Write a message or attach a file before sending."
      return
    }
    if (replyProcess.running) return
    var seenMessages = messages
    if (String(threadId || "") !== id) {
      var cached = cachedThread(id)
      seenMessages = cached && cached.conversation ? cached.conversation.messages : []
    }
    var seen = Model.seenComments(seenMessages)
    replying = true
    replyMessage = ""
    _replyStdout = ""
    _replyStderr = ""
    _replyConversationId = id
    _replySecret = JSON.stringify({ body: body, seen: seen, note: !!asNote, attachments: Model.localAttachments(attachments) })
    replyProcess.command = withTokenFile([root.pluginRoot + "/intercom-fetch", "--reply", id])
    replyProcess.running = true
    replyWatchdog.restart()
  }

  function applyReply(raw, exitCode) {
    var parsed = Model.parseFetch(raw)
    var scheduledId = String(_sendingScheduledId || "")
    var requestedId = _replyConversationId
    _replyConversationId = ""
    _sendingScheduledId = ""
    if (exitCode !== 0 && parsed.state === "error" && parsed.message === "Could not parse Intercom response.") {
      var stderr = String(_replyStderr || "").replace(/\s+/g, " ").trim()
      parsed.message = stderr === "" ? "Could not send the reply." : stderr
    }
    applyIdentity(parsed)
    if (parsed.state === "unconfigured") {
      state = "unconfigured"
      message = parsed.message
      if (scheduledId === "") replyMessage = parsed.message
      return
    }
    if (parsed.state === "error") {
      if (scheduledId === "")
        replyMessage = parsed.message !== "" ? parsed.message : "Could not send the reply."
      var conv = parsed.conversation || {}
      if (String(conv.id || "") !== "") {
        threadCache = Model.writeCachedThread(threadCache, conv, Date.now())
        schedulePersistCache()
        if (String(conv.id) === String(threadId || "") && (conv.messages || []).length)
          showThread(conv)
      }
      return
    }
    var conv = parsed.conversation || {}
    var convId = String(conv.id || requestedId || "")
    if (String(conv.id || "") !== "") {
      threadCache = Model.writeCachedThread(threadCache, conv, Date.now())
      schedulePersistCache()
    }
    if (convId !== "" && convId === String(threadId || "") && (conv.messages || []).length)
      showThread(conv)
    replyMessage = ""
    if (scheduledId !== "") {
      scheduled = Model.removeScheduled(scheduled, scheduledId)
      persistScheduled()
      refreshNow(convId)
      Qt.callLater(root.sendDueScheduled)
      return
    }
    discardDraft(requestedId)
    root.replySent(requestedId)
    refreshNow(convId)
  }

  function closeConversation(conversationId) {
    changeConversationState(conversationId, "close")
  }

  function reopenConversation(conversationId) {
    changeConversationState(conversationId, "reopen")
  }

  function spamConversation(conversationId) {
    changeConversationState(conversationId, "spam")
  }

  function withoutSpam(rows) {
    return Model.withoutSpam(rows, blockedSenders, blockedConversations)
  }

  function dropSpamSender(conversationId, senderId) {
    var senders = Model.copyIdMap(blockedSenders)
    senders[senderId] = true
    blockedSenders = senders
    var ids = Model.copyIdMap(blockedConversations)
    ids[conversationId] = true
    var rows = conversations.concat(openConversations, Model.inboxCacheConversations(inboxCache),
      Model.cachedConversations(threadCache))
    var known = {}
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      if (!Model.conversationIsSpam(row, senders, ids)) continue
      ids[row.id] = true
      if (known[row.id]) continue
      known[row.id] = true
      var previous = Model.conversationStateOf(row)
      if (previous === "open") openCount = Math.max(0, openCount - 1)
      else if (previous === "closed") closedCount = Math.max(0, closedCount - 1)
      else if (previous === "snoozed") snoozedCount = Math.max(0, snoozedCount - 1)
      allCount = Math.max(0, allCount - 1)
      if (Model.findConversationById(conversations, row.id)) waitingCount = Math.max(0, waitingCount - 1)
    }
    blockedConversations = ids
    conversations = withoutSpam(conversations)
    openConversations = withoutSpam(openConversations)
    var sources = ["open", "closed", "snoozed", "all"]
    for (var s = 0; s < sources.length; s++) {
      var snap = Model.readInboxCache(inboxCache, sources[s])
      if (snap.fetchedAt > 0)
        rememberInbox(sources[s], withoutSpam(snap.conversations), inboxCountForSource(sources[s]))
    }
    var cache = Model.copyIdMap(threadCache)
    var reads = Model.copyIdMap(localReadState)
    var moves = Model.copyIdMap(pendingInboxMoves)
    for (var id in ids) {
      delete cache[id]
      delete reads[id]
      delete moves[id]
      discardDraft(id)
    }
    threadCache = cache
    localReadState = reads
    pendingInboxMoves = moves
    pendingUrgent = Model.localUnreadConversations(reads)
    refreshBarUrgent()
    scheduled = scheduled.filter(function(item) { return !ids[item.conversationId] })
    persistScheduled()
    archiveSearchHits = withoutSpam(archiveSearchHits)
    if (ids[threadId]) loadThread("")
    schedulePersistCache()
  }

  function changeConversationState(conversationId, action) {
    var id = String(conversationId || "").trim()
    var kind = action === "spam" ? "spam" : (action === "reopen" ? "reopen" : "close")
    if (!Model.isSafeConversationId(id)) {
      message = "Select a conversation first."
      return
    }
    if (closeProcess.running || replyProcess.running) return
    closing = kind === "close"
    reopening = kind === "reopen"
    markingSpam = kind === "spam"
    _stateChangeId = id
    _stateChangeAction = kind
    _closeStdout = ""
    _closeStderr = ""
    closeProcess.command = withTokenFile([
      root.pluginRoot + "/intercom-fetch",
      "--" + kind,
      id
    ])
    closeProcess.running = true
    closeWatchdog.restart()
  }

  function dropClosedConversation(conversationId, conversation) {
    var id = String(conversationId || "").trim()
    if (id === "") return
    if (Model.findConversationById(conversations, id))
      waitingCount = Math.max(0, waitingCount - 1)
    var previous = previousInboxState(id)
    var row = inboxRowForStateChange(id, conversation, "closed")
    conversations = Model.removeConversation(conversations, id)
    syncInboxCaches(row, "closed", previous)
    applyVisibleInboxAfterStateChange(row, "closed")
    seedThreadCache([row])
    schedulePersistCache()
  }

  function markConversationOpen(conversationId, conversation) {
    var id = String(conversationId || "").trim()
    if (id === "") return
    var previous = previousInboxState(id)
    var row = inboxRowForStateChange(id, conversation, "open")
    conversations = Model.setConversationState(conversations, id, "open")
    var conv = conversation && String(conversation.id || "") !== "" ? conversation : null
    if (conv) {
      conv = Model.setConversationState([conv], conv.id, "open")[0]
      threadCache = Model.writeCachedThread(threadCache, conv, Date.now())
      if (String(threadId || "") === id)
        showThread(conv)
    } else {
      var entry = Model.readCachedThread(threadCache, id)
      if (entry && entry.conversation) {
        var cached = Model.setConversationState([entry.conversation], id, "open")[0]
        threadCache = Model.writeCachedThread(threadCache, cached, entry.fetchedAt, entry.complete)
        if (String(threadId || "") === id)
          showThread(cached)
      } else if (String(threadId || "") === id && thread && String(thread.id || "") === id) {
        showThread(Model.setConversationState([thread], id, "open")[0])
      }
    }
    syncInboxCaches(row, "open", previous)
    applyVisibleInboxAfterStateChange(row, "open")
    schedulePersistCache()
  }

  function previousInboxState(conversationId) {
    var id = String(conversationId || "").trim()
    return Model.conversationStateOf(
      Model.findConversationById(openConversations, id)
      || Model.findConversationById(conversations, id)
      || Model.findConversationById(Model.readInboxCache(inboxCache, "open").conversations, id)
      || Model.findConversationById(Model.readInboxCache(inboxCache, "closed").conversations, id)
      || Model.findConversationById(Model.readInboxCache(inboxCache, "snoozed").conversations, id)
      || Model.findConversationById(Model.readInboxCache(inboxCache, "all").conversations, id)
      || (String((thread || {}).id || "") === id ? thread : null)
    )
  }

  function inboxRowForStateChange(conversationId, conversation, nextState) {
    var id = String(conversationId || "").trim()
    var row = conversation && String((conversation || {}).id || "") !== ""
      ? conversation
      : (Model.findConversationById(openConversations, id)
        || Model.findConversationById(conversations, id)
        || Model.findConversationById(Model.readInboxCache(inboxCache, "open").conversations, id)
        || Model.findConversationById(Model.readInboxCache(inboxCache, "closed").conversations, id)
        || Model.findConversationById(Model.readInboxCache(inboxCache, "snoozed").conversations, id)
        || Model.findConversationById(Model.readInboxCache(inboxCache, "all").conversations, id)
        || (String((thread || {}).id || "") === id ? thread : null)
        || { id: id })
    return Model.conversationForState(row, nextState, Date.now())
  }

  function syncInboxCaches(conversation, nextState, previousState) {
    var row = conversation || {}
    var id = String(row.id || "")
    if (id === "") return
    var target = nextState === "closed" ? "closed" : "open"
    var previous = previousState !== undefined && previousState !== null && String(previousState) !== ""
      ? Model.conversationStateOf({ state: previousState })
      : previousInboxState(id)
    if (previous !== target) {
      if (previous === "open") openCount = Math.max(0, openCount - 1)
      else if (previous === "closed") closedCount = Math.max(0, closedCount - 1)
      else if (previous === "snoozed") snoozedCount = Math.max(0, snoozedCount - 1)
      if (target === "open") openCount += 1
      else if (target === "closed") closedCount += 1
    }
    var now = Date.now()
    var sources = ["open", "closed", "snoozed"]
    for (var i = 0; i < sources.length; i++) {
      var source = sources[i]
      var snap = Model.readInboxCache(inboxCache, source)
      var existed = !!Model.findConversationById(snap.conversations, id)
      var known = existed || snap.fetchedAt > 0 || source === target
      if (!known) continue
      var rows = source === target
        ? Model.prependConversation(snap.conversations, row)
        : Model.removeConversation(snap.conversations, id)
      inboxCache = Model.writeInboxCache(inboxCache, source, rows, inboxCountForSource(source), source === target ? now : snap.fetchedAt, snap.nextCursor)
    }
    var allSnap = Model.readInboxCache(inboxCache, "all")
    if (allSnap.fetchedAt > 0 || allSnap.conversations.length) {
      var allRows = Model.findConversationById(allSnap.conversations, id)
        ? Model.prependConversation(Model.setConversationState(allSnap.conversations, id, target), row)
        : Model.prependConversation(allSnap.conversations, row)
      inboxCache = Model.writeInboxCache(inboxCache, "all", allRows, allCount, now, allSnap.nextCursor)
    }
    pendingInboxMoves = Model.setPendingInboxMove(pendingInboxMoves, row, target, now)
  }

  function applyVisibleInboxAfterStateChange(conversation, nextState) {
    var row = conversation || {}
    var id = String(row.id || "")
    var current = Model.inboxFetchFilter(inboxFilter)
    var mode = Model.inboxFilterMode(inboxFilter)
    if (mode === "all") {
      if (Model.findConversationById(openConversations, id))
        openConversations = Model.prependConversation(Model.setConversationState(openConversations, id, nextState), row)
      else
        openConversations = Model.prependConversation(openConversations, row)
    } else if (current === nextState && mode !== "waiting") {
      openConversations = Model.prependConversation(Model.removeConversation(openConversations, id), row)
    } else {
      openConversations = Model.removeConversation(openConversations, id)
    }
    rememberInbox(current, openConversations, inboxCountForSource(current))
  }

  function applyConversationPart(raw, exitCode) {
    var action = String(_stateChangeAction || "close")
    var verb = action === "spam" ? "mark as spam" : (action === "reopen" ? "reopen" : "close")
    var parsed = Model.parseFetch(raw)
    if (exitCode !== 0 && parsed.state === "error" && parsed.message === "Could not parse Intercom response.") {
      var stderr = String(_closeStderr || "").replace(/\s+/g, " ").trim()
      parsed.message = stderr === "" ? "Could not " + verb + " the conversation." : stderr
    }
    applyIdentity(parsed)
    var changedId = String(_stateChangeId || "")
    _stateChangeId = ""
    _stateChangeAction = ""
    if (parsed.state === "unconfigured") {
      state = "unconfigured"
      message = parsed.message
      return
    }
    if (parsed.state === "error") {
      var detail = parsed.message !== "" ? parsed.message : "Could not " + verb + " the conversation."
      message = detail
      threadMessage = detail
      return
    }
    if (action === "spam") {
      var response = JSON.parse(raw)
      dropSpamSender(changedId, String(response.senderId || ""))
      root.senderMarkedSpam(changedId)
    } else if (action === "reopen") {
      markConversationOpen(changedId, parsed.conversation)
      root.conversationReopened(changedId)
    } else {
      dropClosedConversation(changedId, parsed.conversation)
      root.conversationClosed(changedId)
    }
    refresh()
    loadInbox()
  }

  function syncCommand() {
    return withTokenFile([root.pluginRoot + "/intercom-fetch", "--sync"])
  }

  function applySyncStatus(raw) {
    var parsed = Model.parseSyncStatus(raw)
    if (parsed.state === "" && parsed.message === "" && parsed.scanned === 0 && parsed.total === 0)
      return
    syncState = parsed.state
    syncMessage = parsed.message
    syncScanned = parsed.scanned
    syncTotal = parsed.total
    if (parsed.state === "syncing" && !syncProcess.running && !syncing) {
      syncState = "error"
      syncMessage = "Archive sync was interrupted."
    }
    if (syncProcess.running) syncWatchdog.restart()
  }

  function applySyncFinish(raw, exitCode) {
    var text = String(raw || "").trim()
    var parsed = Model.parseSyncStatus(text)
    if (parsed.state === "" && text !== "") {
      var fetchParsed = Model.parseFetch(text)
      parsed.state = fetchParsed.state
      parsed.message = fetchParsed.message
    }
    if (parsed.state === "unconfigured") {
      state = "unconfigured"
      message = parsed.message
      syncState = "error"
      syncMessage = parsed.message
    } else if (parsed.state === "ready" || parsed.state === "error") {
      syncState = parsed.state
      if (parsed.message !== "") syncMessage = parsed.message
      if (parsed.scanned > 0) syncScanned = parsed.scanned
      if (parsed.total > 0) syncTotal = parsed.total
    } else if (exitCode !== 0) {
      syncState = "error"
      if (syncMessage === "" || parsed.state === "syncing" || parsed.state === "")
        syncMessage = "Archive sync was interrupted."
    }
    if (syncStatusPath !== "") Qt.callLater(function() { syncStatusFile.reload() })
  }

  function startArchiveSync() {
    if (syncProcess.running) return
    syncing = true
    syncState = "syncing"
    syncMessage = "Starting archive sync…"
    _syncStdout = ""
    syncProcess.command = syncCommand()
    syncProcess.running = true
    syncWatchdog.restart()
  }

  function localSearchHits(query) {
    return withoutSpam(Model.searchConversations([
      conversations,
      openConversations,
      Model.cachedConversations(threadCache),
      Model.inboxCacheConversations(inboxCache),
      Model.archiveIndexConversations(archiveIndex)
    ], query, Model.searchLimit()))
  }

  function applyArchiveIndex(raw) {
    archiveIndex = Model.parseArchiveIndex(raw)
  }

  function searchConversations(query, remote) {
    var text = String(query || "").trim()
    if (text === "") {
      archiveSearchHits = []
      searchMessage = ""
      searching = false
      return
    }
    if (searchProcess.running) {
      searchQueued = text
      searchQueuedRemote = !!remote
      return
    }
    searching = true
    searchRemoteActive = !!remote
    searchMessage = remote ? "Searching Intercom…" : ""
    _searchStdout = ""
    _searchStderr = ""
    var command = [root.pluginRoot + "/intercom-fetch", "--search", text, "--limit", String(Model.searchLimit())]
    if (remote) command.push("--remote")
    searchProcess.command = withTokenFile(command)
    searchProcess.running = true
    searchWatchdog.restart()
  }

  function applySearch(raw, exitCode) {
    var parsed = Model.parseFetch(raw)
    if (exitCode !== 0 && parsed.state === "error" && parsed.message === "Could not parse Intercom response.") {
      var stderr = String(_searchStderr || "").replace(/\s+/g, " ").trim()
      parsed.message = stderr === "" ? "Could not search conversations." : stderr
    }
    applyIdentity(parsed)
    searching = false
    if (parsed.state === "unconfigured") {
      searchMessage = parsed.message
      archiveSearchHits = []
    } else if (parsed.state === "error") {
      searchMessage = parsed.message !== "" ? parsed.message : "Could not search conversations."
      if (!searchRemoteActive) archiveSearchHits = []
    } else {
      archiveSearchHits = withoutSpam(parsed.conversations)
      searchMessage = parsed.message
    }
    if (searchQueued !== "") {
      var next = searchQueued
      var remote = searchQueuedRemote
      searchQueued = ""
      searchQueuedRemote = false
      Qt.callLater(function() { root.searchConversations(next, remote) })
    }
  }

  property string _stdout: ""
  property string _stderr: ""
  property string _saveStdout: ""
  property string _saveStderr: ""
  property string _saveSecret: ""
  property string _loginStdout: ""
  property string _loginStderr: ""
  property string _loginSecret: ""
  property string _logoutStdout: ""
  property string _logoutStderr: ""
  property string _replyStdout: ""
  property string _replyStderr: ""
  property string _replySecret: ""
  property string _replyConversationId: ""
  property string _downloadSecret: ""
  property string _downloadConversationId: ""
  property string _sendingScheduledId: ""
  property string _closeStdout: ""
  property string _closeStderr: ""
  property string _stateChangeId: ""
  property string _stateChangeAction: ""
  property string _syncStdout: ""
  property string _searchStdout: ""
  property string _searchStderr: ""
  property string _inboxStdout: ""
  property string _inboxStderr: ""
  property string _inboxRequested: "open"
  property string _inboxCursor: ""
  property bool _inboxTimedOut: false
  property bool _inboxCancelled: false
  property bool _inboxInFlight: false
  property string _threadStdout: ""
  property string _threadStderr: ""
  property string _prefetchStdout: ""
  property string _prefetchStderr: ""

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalMs
    repeat: true
    running: false
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: watchdog
    interval: 120000
    repeat: false
    onTriggered: {
      if (fetchProcess.running) fetchProcess.running = false
    }
  }

  Process {
    id: fetchProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: fetchStdout
      waitForEnd: true
      onStreamFinished: root._stdout = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._stderr = text
    }
    onExited: function(exitCode) {
      watchdog.stop()
      root.loading = false
      var stdout = String(fetchStdout.text || root._stdout || "")
      root.applyOutput(stdout, exitCode)
      if (root.refreshQueued) Qt.callLater(root.refresh)
    }
  }

  Process {
    id: saveProcess
    running: false
    command: []
    stdinEnabled: true
    stdout: StdioCollector {
      id: saveStdout
      waitForEnd: true
      onStreamFinished: root._saveStdout = text
    }
    stderr: StdioCollector {
      id: saveStderr
      waitForEnd: true
      onStreamFinished: root._saveStderr = text
    }
    onStarted: {
      if (root._saveSecret !== "") write(root._saveSecret + "\n")
      root._saveSecret = ""
    }
    onExited: function(exitCode) {
      root.savingToken = false
      var stdout = String(saveStdout.text || root._saveStdout || "")
      var parsed = Model.parseFetch(stdout)
      root.applyIdentity(parsed)
      if (exitCode === 0 && parsed.state === "saved") {
        root.tokenSaved()
        root.refresh()
        return
      }
      root.state = "error"
      if (parsed.message !== "") root.message = parsed.message
      else {
        var stderr = String(saveStderr.text || root._saveStderr || "").replace(/\s+/g, " ").trim()
        root.message = stderr === "" ? "Could not save the Intercom token." : stderr
      }
    }
  }

  Timer {
    id: loginWatchdog
    interval: 180000
    repeat: false
    onTriggered: {
      if (loginProcess.running) loginProcess.running = false
    }
  }

  Process {
    id: loginProcess
    running: false
    command: []
    stdinEnabled: true
    stdout: StdioCollector {
      id: loginStdout
      waitForEnd: true
      onStreamFinished: root._loginStdout = text
    }
    stderr: StdioCollector {
      id: loginStderr
      waitForEnd: true
      onStreamFinished: root._loginStderr = text
    }
    onStarted: {
      if (root._loginSecret !== "") write(root._loginSecret + "\n")
      root._loginSecret = ""
    }
    onExited: function(exitCode) {
      loginWatchdog.stop()
      root.signingIn = false
      var stdout = String(loginStdout.text || root._loginStdout || "")
      var parsed = Model.parseFetch(stdout)
      root.applyIdentity(parsed)
      if (exitCode === 0 && parsed.state === "saved") {
        root.message = parsed.message !== "" ? parsed.message : "Signed in with Intercom."
        root.tokenSaved()
        root.refresh()
        return
      }
      if (parsed.state === "unconfigured") {
        root.state = "unconfigured"
        root.message = parsed.message !== "" ? parsed.message : "Sign in with Intercom to connect this plugin."
        return
      }
      root.state = "error"
      if (parsed.message !== "") root.message = parsed.message
      else {
        var stderr = String(loginStderr.text || root._loginStderr || "").replace(/\s+/g, " ").trim()
        root.message = stderr === "" ? "Could not sign in with Intercom." : stderr
      }
    }
  }

  Process {
    id: logoutProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: logoutStdout
      waitForEnd: true
      onStreamFinished: root._logoutStdout = text
    }
    stderr: StdioCollector {
      id: logoutStderr
      waitForEnd: true
      onStreamFinished: root._logoutStderr = text
    }
    onExited: function(exitCode) {
      root.signingOut = false
      var stdout = String(logoutStdout.text || root._logoutStdout || "")
      var parsed = Model.parseFetch(stdout)
      if (exitCode === 0 && parsed.state === "unconfigured") {
        root.clearSession()
        root.message = parsed.message !== "" ? parsed.message : "Signed out of Intercom."
        root.signedOut()
        return
      }
      if (parsed.message !== "") root.message = parsed.message
      else {
        var stderr = String(logoutStderr.text || root._logoutStderr || "").replace(/\s+/g, " ").trim()
        root.message = stderr === "" ? "Could not sign out of Intercom." : stderr
      }
      if (parsed.state === "error") root.state = "error"
      root.refresh()
    }
  }

  Timer {
    id: replyWatchdog
    interval: 120000
    repeat: false
    onTriggered: {
      if (replyProcess.running) replyProcess.running = false
    }
  }

  Timer {
    id: downloadWatchdog
    interval: 120000
    onTriggered: { if (downloadProcess.running) downloadProcess.running = false }
  }

  Process {
    id: downloadProcess
    running: false
    stdinEnabled: true
    stdout: StdioCollector { id: downloadStdout; waitForEnd: true }
    onStarted: {
      write(root._downloadSecret + "\n")
      root._downloadSecret = ""
    }
    onExited: function(exitCode) {
      downloadWatchdog.stop()
      root.downloadingAttachment = false
      var parsed = Model.parseFetch(downloadStdout.text)
      var message = parsed.state === "saved" || parsed.state === "error"
        ? parsed.message : "Could not download attachment. Try again."
      if (exitCode !== 0) message = "Attachment download was interrupted. Try again."
      root.setAttachmentMessage(message, root._downloadConversationId)
      root._downloadConversationId = ""
    }
  }

  Process {
    id: replyProcess
    running: false
    command: []
    stdinEnabled: true
    stdout: StdioCollector {
      id: replyStdout
      waitForEnd: true
      onStreamFinished: root._replyStdout = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._replyStderr = text
    }
    onStarted: {
      if (root._replySecret !== "") write(root._replySecret + "\n")
      root._replySecret = ""
    }
    onExited: function(exitCode) {
      replyWatchdog.stop()
      root.replying = false
      var stdout = String(replyStdout.text || root._replyStdout || "")
      root.applyReply(stdout, exitCode)
    }
  }

  Timer {
    id: closeWatchdog
    interval: 45000
    repeat: false
    onTriggered: {
      if (closeProcess.running) closeProcess.running = false
    }
  }

  Process {
    id: closeProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: closeStdout
      waitForEnd: true
      onStreamFinished: root._closeStdout = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._closeStderr = text
    }
    onExited: function(exitCode) {
      closeWatchdog.stop()
      root.closing = false
      root.reopening = false
      root.markingSpam = false
      var stdout = String(closeStdout.text || root._closeStdout || "")
      root.applyConversationPart(stdout, exitCode)
    }
  }

  Timer {
    id: inboxWatchdog
    interval: 120000
    repeat: false
    onTriggered: {
      root._inboxTimedOut = true
      if (inboxProcess.running) inboxProcess.running = false
    }
  }

  Process {
    id: inboxProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: inboxStdout
      waitForEnd: true
      onStreamFinished: root._inboxStdout = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._inboxStderr = text
    }
    onExited: function(exitCode) {
      inboxWatchdog.stop()
      root._inboxInFlight = false
      root.openLoading = false
      var stdout = String(inboxStdout.text || root._inboxStdout || "")
      // A terminated helper can still flush a successful response on exit.
      // Never let it replace the newly selected inbox or its error message.
      if (!root._inboxCancelled) root.applyInbox(stdout, exitCode)
      if (root.inboxQueued) Qt.callLater(root.pumpInboxQueue)
    }
  }

  Timer {
    id: threadWatchdog
    interval: 25000
    repeat: false
    onTriggered: {
      if (threadProcess.running) threadProcess.running = false
    }
  }

  Process {
    id: threadProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: threadStdout
      waitForEnd: true
      onStreamFinished: root._threadStdout = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._threadStderr = text
    }
    onExited: function(exitCode) {
      threadWatchdog.stop()
      var stdout = String(threadStdout.text || root._threadStdout || "")
      root.applyThread(stdout, exitCode)
    }
  }

  Timer {
    id: prefetchTimer
    interval: Model.threadPrefetchGapMs()
    repeat: false
    onTriggered: root.pumpPrefetch()
  }

  Timer {
    id: prefetchWatchdog
    interval: 25000
    repeat: false
    onTriggered: {
      if (prefetchProcess.running) prefetchProcess.running = false
    }
  }

  Process {
    id: prefetchProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: prefetchStdout
      waitForEnd: true
      onStreamFinished: root._prefetchStdout = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._prefetchStderr = text
    }
    onExited: function(exitCode) {
      prefetchWatchdog.stop()
      var stdout = String(prefetchStdout.text || root._prefetchStdout || "")
      root.applyPrefetch(stdout, exitCode)
      root.schedulePrefetch()
    }
  }

  Process {
    id: panelProcess
    running: false
    command: []
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function() {
      if (root.prefsQueued) Qt.callLater(root.savePrefs)
    }
  }

  Timer {
    id: syncWatchdog
    interval: 300000
    repeat: false
    onTriggered: {
      if (syncProcess.running) syncProcess.running = false
    }
  }

  Timer {
    interval: 750
    repeat: true
    running: root.syncing && root.syncStatusPath !== ""
    onTriggered: syncStatusFile.reload()
  }

  Process {
    id: syncProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: syncStdout
      waitForEnd: true
      onStreamFinished: root._syncStdout = text
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(exitCode) {
      syncWatchdog.stop()
      root.syncing = false
      var stdout = String(syncStdout.text || root._syncStdout || "")
      root.applySyncFinish(stdout, exitCode)
      if (root.archiveIndexPath !== "") archiveIndexFile.reload()
    }
  }

  FileView {
    id: syncStatusFile
    path: root.syncStatusPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.applySyncStatus(text())
  }

  FileView {
    id: archiveIndexFile
    path: root.archiveIndexPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyArchiveIndex(text())
    onLoadFailed: root.applyArchiveIndex("")
  }

  Timer {
    id: searchWatchdog
    interval: 45000
    repeat: false
    onTriggered: {
      if (searchProcess.running) searchProcess.running = false
    }
  }

  Process {
    id: searchProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: searchStdout
      waitForEnd: true
      onStreamFinished: root._searchStdout = text
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._searchStderr = text
    }
    onExited: function(exitCode) {
      searchWatchdog.stop()
      var stdout = String(searchStdout.text || root._searchStdout || "")
      root.applySearch(stdout, exitCode)
    }
  }

  FileView {
    id: draftsFile
    path: root.draftsPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyDrafts(text())
    onLoadFailed: root.applyDrafts("")
  }

  FileView {
    id: scheduledFile
    path: root.scheduledPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyScheduled(text())
    onLoadFailed: root.applyScheduled("")
  }

  FileView {
    id: cacheFile
    path: root.cachePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyDiskCache(text())
    onLoadFailed: root.applyDiskCache("")
  }

  Timer {
    id: cachePersistTimer
    interval: 400
    repeat: false
    onTriggered: root.persistCacheNow()
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyLocalPrefs(text())
    onLoadFailed: root.applyLocalPrefs("")
  }

  Process {
    id: draftsDirProc
    running: false
    command: ["mkdir", "-p", root.draftsDir]
    onExited: {
      if (root.draftsPath === "") {
        root.applyDrafts("")
        root.applyScheduled("")
        return
      }
      if (root.draftsLoaded) {
        root.persistDrafts()
      } else {
        draftsFile.reload()
      }
      if (root.scheduledLoaded) {
        root.persistScheduled()
      } else if (root.scheduledPath !== "") {
        scheduledFile.reload()
      } else {
        root.applyScheduled("")
      }
      if (root.cachePath !== "" && !root.cacheLoaded) cacheFile.reload()
      if (root.syncStatusPath !== "") syncStatusFile.reload()
      if (root.archiveIndexPath !== "") archiveIndexFile.reload()
    }
  }

  Component.onCompleted: {
    if (root.configPath !== "") configFile.reload()
    else root.applyLocalPrefs("")
    if (root.draftsDir !== "") draftsDirProc.running = true
    else {
      root.applyDrafts("")
      root.applyScheduled("")
    }
    if (root.cachePath !== "") cacheFile.reload()
    else root.applyDiskCache("")
  }
}
