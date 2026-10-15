.pragma library

var GLYPH = "󰍡"
var OAUTH_REDIRECT_URL = "http://localhost:18741/callback"

function objectValue(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : {}
}

function arrayValue(value) {
  if (Array.isArray(value)) return value
  // Repeater modelData exposes nested arrays as Qt sequence objects. They
  // support array methods, but Array.isArray() is false; copy them into JS.
  if (value && typeof value === "object" && typeof value.length === "number"
      && typeof value.slice === "function")
    return Array.prototype.slice.call(value)
  return []
}

function textValue(value, fallback) {
  if (value === undefined || value === null) return fallback === undefined ? "" : String(fallback)
  return String(value)
}

function numberValue(value, fallback) {
  var parsed = Number(value)
  return isFinite(parsed) ? parsed : (fallback === undefined ? 0 : fallback)
}

function emptyFetch(state, message) {
  return {
    state: state || "error",
    message: textValue(message),
    waitingCount: 0,
    openCount: 0,
    inboxCount: 0,
    closedCount: 0,
    snoozedCount: 0,
    allCount: 0,
    hasInboxCounts: false,
    inboxUrl: "",
    workspaceId: "",
    adminId: "",
    adminName: "",
    adminEmail: "",
    conversations: [],
    conversation: emptyThread(),
    panel: "expanded",
    filter: "open",
    viewed: ""
  }
}

function emptyThread() {
  return { id: "", title: "", url: "", waitingSince: 0, updatedAt: 0, messages: [] }
}

function parseFetch(raw) {
  var text = textValue(raw).trim()
  if (text === "") return emptyFetch("error", "Intercom returned an empty response.")
  try {
    var parsed = JSON.parse(text)
  } catch (error) {
    return emptyFetch("error", "Could not parse Intercom response.")
  }
  if (!parsed || typeof parsed !== "object") return emptyFetch("error", "Could not parse Intercom response.")

  var state = textValue(parsed.state, "error")
  if (state !== "ready" && state !== "unconfigured" && state !== "error" && state !== "saved")
    state = "error"
  var conversations = []
  var source = arrayValue(parsed.conversations)
  for (var i = 0; i < source.length; i++) {
    var row = normalizeConversation(source[i])
    if (row.id !== "") conversations.push(row)
  }
  var hasInboxCounts = parsed.closedCount !== undefined
    || parsed.snoozedCount !== undefined
    || parsed.allCount !== undefined
  return {
    state: state,
    message: textValue(parsed.message),
    waitingCount: Math.max(0, Math.floor(numberValue(parsed.waitingCount, conversations.length))),
    openCount: Math.max(0, Math.floor(numberValue(parsed.openCount, conversations.length))),
    inboxCount: Math.max(0, Math.floor(numberValue(parsed.inboxCount, 0))),
    closedCount: Math.max(0, Math.floor(numberValue(parsed.closedCount, 0))),
    snoozedCount: Math.max(0, Math.floor(numberValue(parsed.snoozedCount, 0))),
    allCount: Math.max(0, Math.floor(numberValue(parsed.allCount, 0))),
    hasInboxCounts: hasInboxCounts,
    inboxUrl: textValue(parsed.inboxUrl),
    workspaceId: textValue(parsed.workspaceId),
    adminId: textValue(parsed.adminId),
    adminName: textValue(parsed.adminName),
    adminEmail: textValue(parsed.adminEmail),
    conversations: conversations,
    conversation: normalizeThread(parsed.conversation),
    panel: panelMode(parsed.panel),
    filter: inboxFilterMode(parsed.filter),
    viewed: isSafeConversationId(parsed.viewed) ? textValue(parsed.viewed) : ""
  }
}

function normalizeConversation(value) {
  var conv = objectValue(value)
  return {
    id: textValue(conv.id),
    title: textValue(conv.title, "Conversation"),
    from: textValue(conv.from),
    email: textValue(conv.email),
    snippet: textValue(conv.snippet),
    url: textValue(conv.url),
    state: textValue(conv.state),
    waitingSince: Math.max(0, Math.floor(numberValue(conv.waitingSince, 0))),
    updatedAt: Math.max(0, Math.floor(numberValue(conv.updatedAt, 0))),
    messages: normalizeMessages(conv.messages)
  }
}

function normalizeMessage(value) {
  var msg = objectValue(value)
  var kind = textValue(msg.kind, "customer").toLowerCase()
  if (kind !== "customer" && kind !== "teammate" && kind !== "note" && kind !== "bot")
    kind = "customer"
  var row = {
    id: textValue(msg.id),
    from: textValue(msg.from),
    email: textValue(msg.email),
    kind: kind,
    createdAt: Math.max(0, Math.floor(numberValue(msg.createdAt, 0))),
    body: textValue(msg.body)
  }
  var blocks = normalizeMessageBlocks(msg.blocks)
  if (blocks.length > 0) row.blocks = blocks
  return row
}

function normalizeMessages(value) {
  var messages = []
  var source = arrayValue(value)
  for (var i = 0; i < source.length; i++) {
    var row = normalizeMessage(source[i])
    if (row.body !== "" || arrayValue(row.blocks).length > 0) messages.push(row)
  }
  return messages
}

function normalizeThread(value) {
  var conv = objectValue(value)
  if (textValue(conv.id) === "") return emptyThread()
  var row = normalizeConversation(conv)
  row.messages = normalizeMessages(conv.messages)
  return row
}

function formatRelative(unixSec, nowMs) {
  var since = numberValue(unixSec, 0)
  if (since <= 0) return ""
  var nowSec = Math.floor(numberValue(nowMs, Date.now()) / 1000)
  var seconds = Math.max(0, nowSec - since)
  if (seconds < 45) return "just now"
  if (seconds < 3600) return Math.max(1, Math.round(seconds / 60)) + "m"
  if (seconds < 86400) return Math.max(1, Math.round(seconds / 3600)) + "h"
  return Math.max(1, Math.round(seconds / 86400)) + "d"
}

function formatWaiting(waitingSince, nowMs) {
  return formatRelative(waitingSince, nowMs)
}

function formatMessageTime(createdAt, nowMs) {
  return formatRelative(createdAt, nowMs)
}

function barCount(value) {
  return String(Math.max(0, Math.floor(numberValue(value, 0))))
}

function barLabel(waiting, openCount, vertical) {
  var counts = barCount(waiting) + "/" + barCount(openCount)
  if (vertical) return GLYPH + "\n" + counts
  return GLYPH + " " + counts
}

function tooltipText(waiting, openCount, state, message) {
  if (state === "unconfigured") return "Intercom · sign in"
  if (state === "error") {
    var detail = textValue(message).replace(/\s+/g, " ").trim()
    return detail === "" ? "Intercom · could not refresh" : "Intercom · " + detail
  }
  if (state === "loading") {
    var checking = textValue(message).replace(/\s+/g, " ").trim()
    return checking === "" ? "Checking Intercom…" : checking
  }
  return barCount(waiting) + " waiting · " + barCount(openCount) + " open"
}

function heroMeta(state, message, count) {
  if (state === "unconfigured") return "Sign in with Intercom to connect"
  if (state === "error") {
    var detail = textValue(message).replace(/\s+/g, " ").trim()
    return detail === "" ? "Could not refresh Intercom" : detail
  }
  if (state !== "ready") return "Checking Intercom…"
  var waiting = Math.max(0, Math.floor(numberValue(count, 0)))
  if (waiting === 0) return "No conversations are waiting for a reply"
  if (waiting === 1) return "1 conversation waiting for a reply"
  return waiting + " conversations waiting for a reply"
}

function heroDetail(state, count) {
  if (state === "unconfigured") return "SETUP"
  if (state === "error") return "ERROR"
  if (state !== "ready") return "…"
  return Math.max(0, Math.floor(numberValue(count, 0))) > 0 ? "WAITING" : "CLEAR"
}

function statusMessage(state, message) {
  if (state === "ready") return ""
  return textValue(message)
}

function isSafeHttpUrl(value) {
  var text = textValue(value).trim()
  if (text === "") return false
  var lower = text.toLowerCase()
  return lower.indexOf("https://") === 0 || lower.indexOf("http://") === 0
}

function safeImageUrl(value) {
  var url = textValue(value).trim()
  if (/[\s\x00-\x1f\x7f\\]/.test(url)) return ""
  var match = url.match(/^https?:\/\/(\[[0-9a-f:]+\]|[a-z0-9.-]+)(?::([0-9]{1,5}))?(?:[/?#].*)?$/i)
  if (!match || (match[2] && Number(match[2]) > 65535)) return ""
  return url
}

function autoLoadImage(value) {
  var block = objectValue(value)
  if (numberValue(block.width, 0) === 1 && numberValue(block.height, 0) === 1) return false
  var match = safeImageUrl(block.url).match(/^https:\/\/([^/:?#]+)(?:[/?#]|$)/i)
  if (!match) return false
  // Exact domain boundaries, not substring matching. Other hosts require consent.
  return /(^|\.)(intercomcdn\.com|intercomassets\.com|intercom-attachments-[1-9]\.com)$/i.test(match[1])
}

function imageIdentity(value) {
  var url = textValue(value).split("#")[0]
  var at = url.indexOf("?")
  if (at < 0) return url
  var parts = url.slice(at + 1).split("&")
  var stable = []
  for (var i = 0; i < parts.length; i++) {
    var key = parts[i].split("=")[0]
    try { key = decodeURIComponent(key) } catch (error) { /* Keep malformed keys verbatim. */ }
    key = key.toLowerCase()
    if (/^(signature|sig|expires|token|policy|key-pair-id|awsaccesskeyid)$/.test(key) || /^x-(amz|goog)-/.test(key)) continue
    stable.push(parts[i])
  }
  return url.slice(0, at) + (stable.length > 0 ? "?" + stable.join("&") : "")
}

function normalizeMessageBlocks(value) {
  var source = arrayValue(value)
  var blocks = []
  for (var i = 0; i < source.length; i++) {
    var block = objectValue(source[i])
    if (block.type === "text") {
      // Images belong only in dedicated delegates, never in Qt's HTML renderer.
      var text = textValue(block.text).replace(/<img\b[^>]*>/gi, "")
      if (text.trim() !== "") blocks.push({ type: "text", text: text })
    } else if (block.type === "image") {
      var url = safeImageUrl(block.url)
      if (url === "") continue
      blocks.push({
        type: "image", url: url,
        name: textValue(block.name), alt: textValue(block.alt, "Image"),
        width: Math.max(0, Math.min(32768, Math.floor(numberValue(block.width, 0)))),
        height: Math.max(0, Math.min(32768, Math.floor(numberValue(block.height, 0)))),
        linkUrl: safeImageUrl(block.linkUrl) || url
      })
    } else if (block.type === "attachment") {
      var attachmentUrl = safeImageUrl(block.url)
      if (attachmentUrl === "") continue
      blocks.push({
        type: "attachment", url: attachmentUrl,
        name: textValue(block.name, "Attachment"), contentType: textValue(block.contentType),
        size: Math.max(0, Math.floor(numberValue(block.size, 0)))
      })
    }
  }
  return blocks
}

function messageBlocks(value) {
  var msg = objectValue(value)
  var blocks = normalizeMessageBlocks(msg.blocks)
  if (blocks.length === 0) blocks = [{ type: "text", text: textValue(msg.body).replace(/<img\b[^>]*>/gi, "") }]
  var out = []
  for (var i = 0; i < blocks.length; i++) {
    if (blocks[i].type !== "text") out.push(blocks[i])
    else {
      var paragraphs = messageParagraphs(blocks[i].text)
      for (var j = 0; j < paragraphs.length; j++) out.push({ type: "text", text: paragraphs[j] })
    }
  }
  return out
}

function attachmentName(value) {
  var path = textValue(value)
  return path.slice(path.lastIndexOf("/") + 1) || "Attachment"
}

function downloadAttachmentName(value) {
  var row = objectValue(value)
  var name = textValue(row.name)
  if (name === "") {
    name = textValue(row.url).split(/[?#]/)[0]
    try { name = decodeURIComponent(name) } catch (error) { /* Use the encoded name. */ }
  }
  name = attachmentName(name).replace(/[\x00-\x1f\x7f\\]/g, "_")
  return name === "." || name === ".." ? "Attachment" : name
}

function attachmentSize(value) {
  var size = Math.max(0, numberValue(value, 0))
  if (size === 0) return ""
  if (size < 1024) return Math.floor(size) + " B"
  if (size < 1024 * 1024) return (size / 1024).toFixed(1) + " KiB"
  return (size / (1024 * 1024)).toFixed(1) + " MiB"
}

function localAttachments(value) {
  var source = arrayValue(value)
  var paths = []
  for (var i = 0; i < source.length; i++) {
    var path = textValue(source[i])
    if (path.indexOf("file://") === 0) {
      if (path.indexOf("file:///") !== 0) continue
      try { path = decodeURIComponent(path.slice(7)) } catch (error) { continue }
    }
    if (path.charAt(0) !== "/" || path.indexOf("\x00") >= 0 || paths.indexOf(path) >= 0) continue
    paths.push(path)
  }
  return paths
}

function hasDraft(drafts, conversationId) {
  var entry = draftEntry(drafts, conversationId)
  return entry.body.trim() !== "" || localAttachments(entry.attachments).length > 0
}

function composerPreview(body, attachments) {
  var text = markdownToStyled(body)
  var names = localAttachments(attachments).map(function(path) {
    return escapeStyled(attachmentName(path))
  })
  return text + (names.length ? (text ? "<br><br>" : "") + "Attachments: " + names.join(", ") : "")
}

function isWordChar(value) {
  return /[A-Za-z0-9]/.test(textValue(value))
}

function escapeStyled(value) {
  return textValue(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
}

function escapeStyledAttr(value) {
  return escapeStyled(value).replace(/"/g, "&quot;")
}

function markdownInline(text) {
  var source = textValue(text)
  var out = ""
  var i = 0
  while (i < source.length) {
    if (source.charAt(i) === "*" && source.charAt(i + 1) === "*") {
      var boldEnd = source.indexOf("**", i + 2)
      if (boldEnd >= 0) {
        out += "<b>" + escapeStyled(source.slice(i + 2, boldEnd)) + "</b>"
        i = boldEnd + 2
        continue
      }
    }
    if (source.charAt(i) === "_" && source.charAt(i + 1) === "_") {
      var underEnd = source.indexOf("__", i + 2)
      if (underEnd >= 0) {
        out += "<b>" + escapeStyled(source.slice(i + 2, underEnd)) + "</b>"
        i = underEnd + 2
        continue
      }
    }
    if (source.charAt(i) === "*" && source.charAt(i + 1) !== "*") {
      var italicEnd = source.indexOf("*", i + 1)
      if (italicEnd > i + 1) {
        out += "<i>" + escapeStyled(source.slice(i + 1, italicEnd)) + "</i>"
        i = italicEnd + 1
        continue
      }
    }
    if (source.charAt(i) === "_" && source.charAt(i + 1) !== "_" && (i === 0 || !isWordChar(source.charAt(i - 1)))) {
      var emEnd = source.indexOf("_", i + 1)
      if (emEnd > i + 1 && !isWordChar(source.charAt(emEnd + 1))) {
        out += "<i>" + escapeStyled(source.slice(i + 1, emEnd)) + "</i>"
        i = emEnd + 1
        continue
      }
    }
    if (source.charAt(i) === "[") {
      var close = source.indexOf("](", i + 1)
      var finish = close >= 0 ? source.indexOf(")", close + 2) : -1
      if (close > i && finish > close) {
        var label = source.slice(i + 1, close)
        var href = source.slice(close + 2, finish).trim()
        if (isSafeHttpUrl(href)) {
          out += '<a href="' + escapeStyledAttr(href) + '">' + escapeStyled(label) + "</a>"
          i = finish + 1
          continue
        }
      }
    }
    out += escapeStyled(source.charAt(i))
    i += 1
  }
  return out
}

function markdownToStyled(value) {
  var text = textValue(value).replace(/\r\n/g, "\n").replace(/\r/g, "\n")
  if (text.trim() === "") return ""
  var lines = text.split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++)
    out.push(markdownInline(lines[i]))
  return out.join("<br>")
}

function messageParagraphs(value) {
  var text = textValue(value)
  if (text.trim() === "") return []
  var normalized = text.replace(/<br\s*\/?>/gi, "<br>").replace(/\n\n+/g, "<br><br>")
  var parts = normalized.split(/<br>(?:\s*<br>)+/)
  var out = []
  for (var i = 0; i < parts.length; i++) {
    var part = parts[i]
    while (part.indexOf("<br>") === 0)
      part = part.slice(4)
    while (part.length >= 4 && part.slice(part.length - 4) === "<br>")
      part = part.slice(0, part.length - 4)
    part = part.replace(/&nbsp;/g, " ").trim()
    if (part !== "") out.push(part)
  }
  return out.length ? out : [normalized]
}

function adminLabel(name, email, fallback) {
  var label = textValue(name).trim()
  if (label !== "") return label
  label = textValue(email).trim()
  if (label !== "") return label
  return textValue(fallback).trim()
}

function adminInitials(name, email) {
  var label = textValue(name).replace(/\s+/g, " ").trim()
  if (label !== "") {
    var parts = label.split(" ")
    var first = parts[0].charAt(0)
    var last = parts.length > 1 ? parts[parts.length - 1].charAt(0) : ""
    return (first + last).toUpperCase()
  }
  var mail = textValue(email).trim()
  if (mail !== "") return mail.charAt(0).toUpperCase()
  return ""
}

function adminEmailLine(name, email) {
  var mail = textValue(email).trim()
  if (mail === "") return ""
  if (mail === adminLabel(name, email, "")) return ""
  return mail
}

function hasAdminProfile(name, email) {
  return adminLabel(name, email, "") !== ""
}

function isSignedIn(state, name, email, adminId) {
  if (textValue(state) === "unconfigured") return false
  if (textValue(state) === "ready") return true
  return textValue(adminId).trim() !== "" || adminLabel(name, email, "") !== ""
}

function conversationWaiting(value) {
  return numberValue(objectValue(value).waitingSince, 0) > 0
}

function panelMode(value) {
  var text = textValue(value).toLowerCase().trim()
  if (text === "large") return "large"
  return "expanded"
}

function nextPanelMode(value) {
  return panelMode(value) === "large" ? "expanded" : "large"
}

function inboxFilterMode(value) {
  if (value === true) return "waiting"
  if (value === false || value === undefined || value === null) return "open"
  var text = textValue(value).toLowerCase().trim()
  if (text === "waiting" || text === "closed" || text === "snoozed" || text === "all")
    return text
  return "open"
}

function inboxFetchFilter(value) {
  var mode = inboxFilterMode(value)
  return mode === "waiting" ? "open" : mode
}

function parsePrefs(raw) {
  var text = textValue(raw).trim()
  var empty = { panel: "expanded", filter: "open", viewed: "" }
  if (text === "") return empty
  try {
    var parsed = JSON.parse(text)
  } catch (error) {
    return empty
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return empty
  return {
    panel: panelMode(parsed.panel),
    filter: inboxFilterMode(parsed.filter),
    viewed: isSafeConversationId(parsed.viewed) ? textValue(parsed.viewed) : ""
  }
}

function conversationStateOf(value) {
  var state = textValue(objectValue(value).state).toLowerCase()
  if (state === "closed" || state === "snoozed") return state
  return "open"
}

function conversationIsOpen(value) {
  return textValue(objectValue(value).state).trim().toLowerCase() === "open"
}

function copyConversation(value) {
  var row = objectValue(value)
  var copy = {}
  for (var key in row) {
    if (!Object.prototype.hasOwnProperty.call(row, key)) continue
    copy[key] = row[key]
  }
  return copy
}

function setConversationState(conversations, id, state) {
  var wanted = textValue(id)
  var nextState = conversationStateOf({ state: state })
  var source = arrayValue(conversations)
  if (wanted === "") return source
  var rows = []
  for (var i = 0; i < source.length; i++) {
    var row = source[i]
    if (textValue((row || {}).id) !== wanted) {
      rows.push(row)
      continue
    }
    var copy = copyConversation(row)
    copy.state = nextState
    rows.push(copy)
  }
  return rows
}

function conversationForState(value, state, nowMs) {
  var copy = copyConversation(normalizeConversation(value))
  if (copy.id === "") return copy
  copy.state = conversationStateOf({ state: state })
  if (copy.state !== "open") copy.waitingSince = 0
  var nowSec = Math.max(0, Math.floor(numberValue(nowMs, Date.now()) / 1000))
  if (nowSec > copy.updatedAt) copy.updatedAt = nowSec
  return copy
}

function prependConversation(conversations, conversation) {
  var row = normalizeConversation(conversation)
  if (row.id === "") return arrayValue(conversations)
  var rows = [row]
  var source = arrayValue(conversations)
  for (var i = 0; i < source.length; i++) {
    if (textValue((source[i] || {}).id) === row.id) continue
    rows.push(source[i])
  }
  return rows
}

function pendingInboxMoveTtlMs() {
  return 120000
}

function normalizePendingInboxMoves(value, nowMs, ttlMs) {
  var now = Math.floor(numberValue(nowMs, Date.now()))
  var ttl = Math.floor(numberValue(ttlMs, pendingInboxMoveTtlMs()))
  if (ttl < 0) ttl = 0
  var source = objectValue(value)
  var next = {}
  for (var key in source) {
    if (!Object.prototype.hasOwnProperty.call(source, key)) continue
    if (!isSafeConversationId(key)) continue
    var entry = objectValue(source[key])
    var at = Math.max(0, Math.floor(numberValue(entry.at, 0)))
    if (at > 0 && now - at > ttl) continue
    var conv = conversationForState(
      entry.conversation !== undefined ? entry.conversation : entry,
      entry.state,
      at > 0 ? at : now
    )
    if (conv.id === "") conv.id = key
    if (!isSafeConversationId(conv.id)) continue
    next[conv.id] = {
      conversation: conv,
      state: conversationStateOf(conv),
      at: at || now
    }
  }
  return next
}

function setPendingInboxMove(pending, conversation, state, nowMs) {
  var now = Math.floor(numberValue(nowMs, Date.now()))
  var next = normalizePendingInboxMoves(pending, now)
  var row = conversationForState(conversation, state, now)
  if (row.id === "") return next
  next[row.id] = { conversation: row, state: conversationStateOf(row), at: now }
  return next
}

function hasPendingInboxMoves(pending, nowMs) {
  var moves = normalizePendingInboxMoves(pending, nowMs)
  for (var key in moves) {
    if (Object.prototype.hasOwnProperty.call(moves, key)) return true
  }
  return false
}

function applyPendingInboxMoves(conversations, source, pending, nowMs) {
  var moves = normalizePendingInboxMoves(pending, nowMs)
  var mode = inboxSourceKey(source)
  var rows = arrayValue(conversations)
  for (var id in moves) {
    if (!Object.prototype.hasOwnProperty.call(moves, id)) continue
    var move = objectValue(moves[id])
    var state = conversationStateOf(move)
    var conv = objectValue(move.conversation)
    if (textValue(conv.id) === "") conv = move
    if (mode === "all" || mode === state)
      rows = prependConversation(rows, conv)
    else
      rows = removeConversation(rows, id)
  }
  return rows
}

function conversationMatchesInboxFilter(value, filter) {
  var mode = inboxFilterMode(filter)
  var state = conversationStateOf(value)
  if (mode === "all") return true
  if (mode === "waiting") return conversationWaiting(value) && state === "open"
  return state === mode
}

function filterInbox(conversations, filter) {
  var source = arrayValue(conversations)
  var mode = inboxFilterMode(filter)
  if (mode === "all") return source
  var rows = []
  for (var i = 0; i < source.length; i++) {
    if (conversationMatchesInboxFilter(source[i], mode)) rows.push(source[i])
  }
  return rows
}

function emptyInboxMessage(filter) {
  var mode = inboxFilterMode(filter)
  if (mode === "waiting") return "No conversations are waiting."
  if (mode === "closed") return "No closed conversations."
  if (mode === "snoozed") return "No snoozed conversations."
  if (mode === "all") return "No conversations."
  return "No open conversations."
}

function filterChordKey(text) {
  var key = textValue(text).toLowerCase()
  if (key === "o") return "open"
  if (key === "w") return "waiting"
  if (key === "c") return "closed"
  if (key === "s") return "snoozed"
  if (key === "a") return "all"
  return ""
}

function resolveInboxSelection(conversations, filter, wantedId, cursorIndex) {
  var rows = filterInbox(conversations, filter)
  if (rows.length === 0) return { index: 0, id: "" }
  var wanted = textValue(wantedId)
  if (wanted !== "") {
    for (var i = 0; i < rows.length; i++) {
      if (textValue((rows[i] || {}).id) === wanted)
        return { index: i, id: wanted }
    }
  }
  var index = Math.max(0, Math.min(rows.length - 1, Math.floor(numberValue(cursorIndex, 0))))
  return { index: index, id: textValue((rows[index] || {}).id) }
}

function threadCacheTtlMs() {
  return 120000
}

function readCachedThread(cache, conversationId) {
  var id = textValue(conversationId)
  if (id === "") return null
  var entry = objectValue(objectValue(cache)[id])
  var conv = normalizeThread(entry.conversation)
  if (conv.id === "") return null
  return {
    conversation: conv,
    fetchedAt: Math.max(0, Math.floor(numberValue(entry.fetchedAt, 0))),
    complete: entry.complete !== false
  }
}

function writeCachedThread(cache, conversation, nowMs, complete) {
  var next = {}
  var source = objectValue(cache)
  for (var key in source) {
    if (!Object.prototype.hasOwnProperty.call(source, key)) continue
    next[key] = source[key]
  }
  var conv = normalizeThread(conversation)
  if (conv.id === "") return next
  next[conv.id] = {
    conversation: conv,
    fetchedAt: Math.max(0, Math.floor(numberValue(nowMs, Date.now()))),
    complete: complete !== false
  }
  return next
}

function expireCachedThreads(cache, conversations) {
  var next = cache
  var source = arrayValue(conversations)
  for (var i = 0; i < source.length; i++) {
    var entry = readCachedThread(next, conversationId(source[i]))
    if (!entry) continue
    next = writeCachedThread(next, entry.conversation, 0, false)
  }
  return objectValue(next)
}

function cachedThreadFresh(entry, nowMs, ttlMs) {
  if (!entry) return false
  var row = objectValue(entry)
  if (row.complete === false) return false
  var fetchedAt = Math.max(0, Math.floor(numberValue(row.fetchedAt, 0)))
  if (fetchedAt <= 0) return false
  var now = Math.floor(numberValue(nowMs, Date.now()))
  var ttl = Math.floor(numberValue(ttlMs, threadCacheTtlMs()))
  if (ttl < 0) ttl = 0
  return (now - fetchedAt) < ttl
}

function prefetchResultStale(entry, startedAt) {
  if (!entry) return false
  var row = objectValue(entry)
  if (row.complete === false) return false
  var fetchedAt = Math.max(0, Math.floor(numberValue(row.fetchedAt, 0)))
  var started = Math.max(0, Math.floor(numberValue(startedAt, 0)))
  return fetchedAt >= started
}

function threadPrefetchGapMs() {
  return 400
}

function conversationId(value) {
  if (value === undefined || value === null) return ""
  if (typeof value === "string" || typeof value === "number") return textValue(value)
  return textValue(objectValue(value).id)
}

function isSafeConversationId(value) {
  var id = textValue(value)
  return id !== "" && /^[A-Za-z0-9_-]{1,128}$/.test(id)
}

function emptySyncStatus() {
  return {
    state: "",
    message: "",
    scanned: 0,
    stored: 0,
    skipped: 0,
    failed: 0,
    total: 0,
    syncedAt: 0
  }
}

function parseSyncStatus(raw) {
  var text = textValue(raw).trim()
  if (text === "") return emptySyncStatus()
  try {
    var parsed = JSON.parse(text)
  } catch (error) {
    return emptySyncStatus()
  }
  if (!parsed || typeof parsed !== "object") return emptySyncStatus()
  var state = textValue(parsed.state)
  if (state !== "" && state !== "syncing" && state !== "ready" && state !== "error" && state !== "unconfigured")
    state = "error"
  return {
    state: state,
    message: textValue(parsed.message),
    scanned: Math.max(0, Math.floor(numberValue(parsed.scanned, 0))),
    stored: Math.max(0, Math.floor(numberValue(parsed.stored, 0))),
    skipped: Math.max(0, Math.floor(numberValue(parsed.skipped, 0))),
    failed: Math.max(0, Math.floor(numberValue(parsed.failed, 0))),
    total: Math.max(0, Math.floor(numberValue(parsed.total, 0))),
    syncedAt: Math.max(0, Math.floor(numberValue(parsed.syncedAt, 0)))
  }
}

function formatSyncProgress(syncing, scanned, total, message) {
  if (syncing) {
    if (numberValue(total, 0) > 0)
      return "Syncing " + Math.floor(numberValue(scanned, 0)) + " of " + Math.floor(numberValue(total, 0)) + "…"
    if (numberValue(scanned, 0) > 0)
      return "Syncing " + Math.floor(numberValue(scanned, 0)) + " conversations…"
    return "Starting archive sync…"
  }
  return textValue(message)
}

function searchLimit() {
  return 50
}

function searchTokens(query) {
  var text = textValue(query).toLowerCase().trim()
  if (text === "") return []
  var parts = text.split(/\s+/)
  var tokens = []
  for (var i = 0; i < parts.length; i++) {
    if (parts[i] !== "") tokens.push(parts[i])
  }
  return tokens
}

function conversationHaystack(value) {
  var conv = objectValue(value)
  var nested = objectValue(conv.conversation)
  if (textValue(nested.id) !== "") conv = nested
  var parts = [
    conv.id,
    conv.title,
    conv.from,
    conv.email,
    conv.snippet,
    conv.state
  ]
  var messages = arrayValue(conv.messages)
  for (var i = 0; i < messages.length; i++) {
    var msg = objectValue(messages[i])
    parts.push(msg.body, msg.from, msg.email)
    var blocks = arrayValue(msg.blocks)
    for (var b = 0; b < blocks.length; b++) {
      var block = objectValue(blocks[b])
      if (block.type === "image" || block.type === "attachment") parts.push(block.name, block.alt)
    }
  }
  return parts.join("\n").toLowerCase()
}

function conversationMatchesQuery(value, tokens) {
  var wanted = arrayValue(tokens)
  if (wanted.length === 0) return false
  var hay = conversationHaystack(value)
  for (var i = 0; i < wanted.length; i++) {
    if (hay.indexOf(wanted[i]) < 0) return false
  }
  return true
}

function searchHit(value) {
  var conv = objectValue(value)
  var nested = objectValue(conv.conversation)
  if (textValue(nested.id) !== "") conv = nested
  var row = normalizeConversation(conv)
  row.state = textValue(conv.state)
  return row
}

function cachedConversations(cache) {
  var rows = []
  var source = objectValue(cache)
  for (var key in source) {
    if (!Object.prototype.hasOwnProperty.call(source, key)) continue
    var entry = readCachedThread(source, key)
    if (entry && entry.conversation && entry.conversation.id !== "")
      rows.push(entry.conversation)
  }
  return rows
}

function inboxSourceKey(value) {
  var key = inboxFetchFilter(value)
  if (key === "closed" || key === "snoozed" || key === "all") return key
  return "open"
}

function normalizeConversationList(value) {
  var rows = []
  var source = arrayValue(value)
  for (var i = 0; i < source.length; i++) {
    var row = normalizeConversation(source[i])
    if (row.id !== "") rows.push(row)
  }
  return rows
}

function readInboxCache(cache, source) {
  var key = inboxSourceKey(source)
  var row = objectValue(objectValue(cache)[key])
  var conversations = normalizeConversationList(row.conversations)
  return {
    conversations: conversations,
    count: Math.max(0, Math.floor(numberValue(row.count, conversations.length))),
    fetchedAt: Math.max(0, Math.floor(numberValue(row.fetchedAt, 0)))
  }
}

function writeInboxCache(cache, source, conversations, count, nowMs) {
  var next = {}
  var existing = objectValue(cache)
  for (var key in existing) {
    if (!Object.prototype.hasOwnProperty.call(existing, key)) continue
    next[key] = existing[key]
  }
  var rows = normalizeConversationList(conversations)
  next[inboxSourceKey(source)] = {
    conversations: rows,
    count: Math.max(0, Math.floor(numberValue(count, rows.length))),
    fetchedAt: Math.max(0, Math.floor(numberValue(nowMs, Date.now())))
  }
  return next
}

function parseInboxCache(value) {
  var next = {}
  var source = objectValue(value)
  var keys = ["open", "closed", "snoozed", "all"]
  for (var i = 0; i < keys.length; i++) {
    if (!Object.prototype.hasOwnProperty.call(source, keys[i])) continue
    var snap = readInboxCache(source, keys[i])
    if (snap.fetchedAt <= 0 && snap.conversations.length === 0) continue
    next[keys[i]] = snap
  }
  return next
}

function inboxCacheConversations(cache) {
  var rows = []
  var source = parseInboxCache(cache)
  var keys = ["open", "closed", "snoozed", "all"]
  for (var i = 0; i < keys.length; i++) {
    var snap = objectValue(source[keys[i]])
    var list = arrayValue(snap.conversations)
    for (var j = 0; j < list.length; j++)
      rows.push(list[j])
  }
  return rows
}

function parseThreadCache(value) {
  var next = {}
  var source = objectValue(value)
  for (var key in source) {
    if (!Object.prototype.hasOwnProperty.call(source, key)) continue
    var entry = readCachedThread(source, key)
    if (!entry || !entry.conversation || entry.conversation.id === "") continue
    next[entry.conversation.id] = {
      conversation: entry.conversation,
      fetchedAt: entry.fetchedAt,
      complete: entry.complete !== false
    }
  }
  return next
}

function emptyDiskCache() {
  return {
    ready: false,
    fetchedAt: 0,
    state: "loading",
    message: "",
    waitingCount: 0,
    openCount: 0,
    closedCount: 0,
    snoozedCount: 0,
    allCount: 0,
    hasInboxCounts: false,
    inboxUrl: "",
    workspaceId: "",
    adminId: "",
    adminName: "",
    adminEmail: "",
    conversations: [],
    inboxes: {},
    threads: {},
    initialReadBefore: 0,
    localReadState: {}
  }
}

function parseDiskCache(raw) {
  var empty = emptyDiskCache()
  var text = textValue(raw).trim()
  if (text === "") return empty
  try {
    var parsed = JSON.parse(text)
  } catch (error) {
    return empty
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return empty
  var waiting = objectValue(parsed.waiting)
  if (waiting.state === undefined && parsed.conversations !== undefined)
    waiting = parsed
  var conversations = normalizeConversationList(waiting.conversations)
  for (var i = 0; i < conversations.length; i++) {
    if (conversations[i].state === "") conversations[i].state = "open"
  }
  var state = textValue(waiting.state, textValue(parsed.state))
  var hasInboxCounts = waiting.closedCount !== undefined
    || waiting.snoozedCount !== undefined
    || waiting.allCount !== undefined
    || parsed.closedCount !== undefined
  return {
    ready: state === "ready",
    fetchedAt: Math.max(0, Math.floor(numberValue(parsed.fetchedAt, waiting.fetchedAt))),
    state: state === "ready" ? "ready" : empty.state,
    message: textValue(waiting.message, textValue(parsed.message)),
    waitingCount: Math.max(0, Math.floor(numberValue(waiting.waitingCount, conversations.length))),
    openCount: Math.max(0, Math.floor(numberValue(waiting.openCount, 0))),
    closedCount: Math.max(0, Math.floor(numberValue(waiting.closedCount, 0))),
    snoozedCount: Math.max(0, Math.floor(numberValue(waiting.snoozedCount, 0))),
    allCount: Math.max(0, Math.floor(numberValue(waiting.allCount, 0))),
    hasInboxCounts: hasInboxCounts,
    inboxUrl: textValue(waiting.inboxUrl, textValue(parsed.inboxUrl)),
    workspaceId: textValue(waiting.workspaceId, textValue(parsed.workspaceId)),
    adminId: textValue(waiting.adminId, textValue(parsed.adminId)),
    adminName: textValue(waiting.adminName, textValue(parsed.adminName)),
    adminEmail: textValue(waiting.adminEmail, textValue(parsed.adminEmail)),
    conversations: conversations,
    inboxes: parseInboxCache(parsed.inboxes),
    threads: parseThreadCache(parsed.threads),
    initialReadBefore: Math.max(0, Math.floor(numberValue(parsed.initialReadBefore, 0))),
    localReadState: normalizeLocalReadState(parsed.localReadState)
  }
}

function serializeDiskCache(snapshot) {
  var row = objectValue(snapshot)
  if (row.ready === false || textValue(row.state) === "unconfigured")
    return JSON.stringify({ version: 1 })
  var conversations = normalizeConversationList(row.conversations)
  var payload = {
    version: 1,
    fetchedAt: Math.max(0, Math.floor(numberValue(row.fetchedAt, Date.now()))),
    waiting: {
      state: "ready",
      message: textValue(row.message),
      waitingCount: Math.max(0, Math.floor(numberValue(row.waitingCount, conversations.length))),
      openCount: Math.max(0, Math.floor(numberValue(row.openCount, 0))),
      closedCount: Math.max(0, Math.floor(numberValue(row.closedCount, 0))),
      snoozedCount: Math.max(0, Math.floor(numberValue(row.snoozedCount, 0))),
      allCount: Math.max(0, Math.floor(numberValue(row.allCount, 0))),
      inboxUrl: textValue(row.inboxUrl),
      workspaceId: textValue(row.workspaceId),
      adminId: textValue(row.adminId),
      adminName: textValue(row.adminName),
      adminEmail: textValue(row.adminEmail),
      conversations: conversations
    },
    inboxes: parseInboxCache(row.inboxes),
    threads: parseThreadCache(row.threads),
    initialReadBefore: Math.max(0, Math.floor(numberValue(row.initialReadBefore, 0))),
    localReadState: normalizeLocalReadState(row.localReadState)
  }
  return JSON.stringify(payload)
}

function parseArchiveIndex(raw) {
  var text = textValue(raw).trim()
  if (text === "") return {}
  try {
    var parsed = JSON.parse(text)
  } catch (error) {
    return {}
  }
  if (!parsed || typeof parsed !== "object") return {}
  var conversations = parsed.conversations
  if (conversations && typeof conversations === "object" && !Array.isArray(conversations))
    return conversations
  return {}
}

function archiveIndexConversations(index) {
  var source = objectValue(index)
  var rows = []
  for (var key in source) {
    if (!Object.prototype.hasOwnProperty.call(source, key)) continue
    var row = objectValue(source[key])
    if (textValue(row.id) === "") row.id = key
    if (textValue(row.id) !== "") rows.push(row)
  }
  return rows
}

function searchConversations(lists, query, limit) {
  var tokens = searchTokens(query)
  var cap = Math.max(1, Math.floor(numberValue(limit, searchLimit())))
  if (tokens.length === 0) return []
  var seen = {}
  var hits = []
  var sources = arrayValue(lists)
  for (var s = 0; s < sources.length && hits.length < cap; s++) {
    var rows = arrayValue(sources[s])
    for (var i = 0; i < rows.length && hits.length < cap; i++) {
      var raw = objectValue(rows[i])
      if (!conversationMatchesQuery(raw, tokens)) continue
      var hit = searchHit(raw)
      if (hit.id === "" || seen[hit.id]) continue
      seen[hit.id] = true
      hits.push(hit)
    }
  }
  return hits
}

function mergeSearchHits(primary, extra, limit) {
  var cap = Math.max(1, Math.floor(numberValue(limit, searchLimit())))
  var seen = {}
  var hits = []
  var sources = [arrayValue(primary), arrayValue(extra)]
  for (var s = 0; s < sources.length && hits.length < cap; s++) {
    var rows = sources[s]
    for (var i = 0; i < rows.length && hits.length < cap; i++) {
      var hit = searchHit(rows[i])
      if (hit.id === "" || seen[hit.id]) continue
      seen[hit.id] = true
      hits.push(hit)
    }
  }
  return hits
}

function parseDrafts(raw) {
  var text = textValue(raw).trim()
  if (text === "") return {}
  try {
    var parsed = JSON.parse(text)
  } catch (error) {
    return {}
  }
  return normalizeDrafts(parsed)
}

function normalizeDrafts(value) {
  var source = objectValue(value)
  var next = {}
  for (var key in source) {
    if (!Object.prototype.hasOwnProperty.call(source, key)) continue
    if (!isSafeConversationId(key)) continue
    var entry = normalizeDraftEntry(source[key])
    if (entry.body.trim() === "" && !localAttachments(entry.attachments).length) continue
    next[key] = entry
  }
  return next
}

function normalizeDraftEntry(value) {
  if (typeof value === "string" || typeof value === "number") {
    return { body: textValue(value), note: false }
  }
  var row = objectValue(value)
  var entry = { body: textValue(row.body), note: row.note === true }
  var attachments = localAttachments(row.attachments)
  if (attachments.length) entry.attachments = attachments
  return entry
}

function draftEntry(drafts, conversationId) {
  var id = textValue(conversationId)
  if (!isSafeConversationId(id)) return { body: "", note: false }
  var value = objectValue(drafts)[id]
  if (value === undefined || value === null) return { body: "", note: false }
  var entry = normalizeDraftEntry(value)
  if (entry.body.trim() === "" && !localAttachments(entry.attachments).length) return { body: "", note: false }
  return entry
}

function draftText(drafts, conversationId) {
  return draftEntry(drafts, conversationId).body
}

function draftIsNote(drafts, conversationId) {
  return draftEntry(drafts, conversationId).note
}

function setDraft(drafts, conversationId, text, note, attachments) {
  var next = normalizeDrafts(drafts)
  if (!isSafeConversationId(conversationId)) return next
  var body = textValue(text)
  var files = localAttachments(attachments)
  if (body.trim() === "" && !files.length) delete next[conversationId]
  else next[conversationId] = normalizeDraftEntry({ body: body, note: note === true, attachments: files })
  return next
}

function clampCursor(text, cursor) {
  var value = textValue(text)
  var n = Math.floor(numberValue(cursor, 0))
  if (n < 0) return 0
  if (n > value.length) return value.length
  return n
}

function isComposerWhitespace(value) {
  return /\s/.test(textValue(value))
}

function deleteLastWord(text, cursor) {
  var value = textValue(text)
  var end = clampCursor(value, cursor)
  var start = end
  while (start > 0 && isComposerWhitespace(value.charAt(start - 1))) start -= 1
  while (start > 0 && !isComposerWhitespace(value.charAt(start - 1))) start -= 1
  return { text: value.slice(0, start) + value.slice(end), cursor: start }
}

function deleteLineBeforeCursor(text, cursor) {
  var value = textValue(text)
  var end = clampCursor(value, cursor)
  var lineBreak = end === 0 ? -1 : value.lastIndexOf("\n", end - 1)
  var start = lineBreak < 0 ? 0 : lineBreak + 1
  return { text: value.slice(0, start) + value.slice(end), cursor: start }
}

function seenComments(messages) {
  var rows = []
  var source = arrayValue(messages)
  for (var i = 0; i < source.length; i++) {
    var msg = normalizeMessage(source[i])
    if (msg.id === "") continue
    rows.push({ id: msg.id, createdAt: msg.createdAt })
  }
  return rows
}

function findConversationById(conversations, id) {
  var wanted = textValue(id)
  if (wanted === "") return null
  var source = arrayValue(conversations)
  for (var i = 0; i < source.length; i++) {
    var row = normalizeConversation(source[i])
    if (row.id === wanted) return row
  }
  return null
}

function removeConversation(conversations, id) {
  var wanted = textValue(id)
  var source = arrayValue(conversations)
  if (wanted === "") return source
  var rows = []
  for (var i = 0; i < source.length; i++) {
    if (textValue((source[i] || {}).id) === wanted) continue
    rows.push(source[i])
  }
  return rows
}

function adjacentConversation(conversations, id) {
  var wanted = textValue(id)
  var source = arrayValue(conversations)
  var rows = []
  var index = -1
  for (var i = 0; i < source.length; i++) {
    var row = source[i]
    var rowId = textValue((row || {}).id)
    if (rowId === "") continue
    if (rowId === wanted) index = rows.length
    rows.push(row)
  }
  if (index < 0) return null
  if (index + 1 < rows.length) return rows[index + 1]
  if (index - 1 >= 0) return rows[index - 1]
  return null
}

function conversationFingerprint(value) {
  var conv = normalizeConversation(value)
  return {
    id: conv.id,
    waitingSince: conv.waitingSince,
    updatedAt: conv.updatedAt,
    from: conv.from,
    snippet: conv.snippet
  }
}

function copyIdMap(value) {
  var source = objectValue(value)
  var next = {}
  for (var key in source) {
    if (!Object.prototype.hasOwnProperty.call(source, key)) continue
    if (!isSafeConversationId(key)) continue
    next[key] = source[key]
  }
  return next
}

// Only open conversations can be unread; message identities determine which messages.
function normalizeLocalReadState(value) {
  var source = copyIdMap(value)
  var next = {}
  for (var id in source) {
    var messages = objectValue(source[id])
    var copy = {}
    for (var key in messages) {
      if (!Object.prototype.hasOwnProperty.call(messages, key) || key.charAt(0) !== "$") continue
      if (typeof messages[key] === "boolean") copy[key] = messages[key]
    }
    next[id] = copy
  }
  return next
}

function localMessageKey(value) {
  var msg = normalizeMessage(value)
  var identity = [msg.createdAt, msg.kind, msg.from, msg.body]
  var images = arrayValue(msg.blocks).filter(function(block) { return block.type === "image" || block.type === "attachment" })
  if (images.length > 0) identity.push(images.map(function(block) {
    return [imageIdentity(block.url), block.name]
  }))
  return "$" + (msg.id || JSON.stringify(identity))
}

function messageUnread(value, conversationId, message) {
  var id = textValue(conversationId)
  if (!isSafeConversationId(id)) return false
  var known = objectValue(objectValue(value)[id])
  var key = localMessageKey(message)
  return Object.prototype.hasOwnProperty.call(known, key) && known[key] === false
}

function markConversationRead(value, conversationId) {
  var next = normalizeLocalReadState(value)
  var id = textValue(conversationId)
  if (!isSafeConversationId(id)) return next
  var messages = objectValue(next[id])
  for (var key in messages) {
    if (Object.prototype.hasOwnProperty.call(messages, key)) messages[key] = true
  }
  next[id] = messages
  return next
}

function updateLocalReadState(value, conversation, read, ownEmail, initialReadBefore) {
  var next = normalizeLocalReadState(value)
  var conv = normalizeConversation(conversation)
  if (!isSafeConversationId(conv.id)) return next
  if (!conversationIsOpen(conv)) {
    next = markConversationRead(next, conv.id)
    read = true
  }
  var known = objectValue(next[conv.id])
  var email = textValue(ownEmail).trim().toLowerCase()
  for (var i = 0; i < conv.messages.length; i++) {
    var msg = conv.messages[i]
    // Sending our own reply or note must not create an unread alert.
    if (email !== "" && (msg.kind === "teammate" || msg.kind === "note")
        && msg.email.trim().toLowerCase() === email) continue
    var key = localMessageKey(msg)
    // Full threads can reveal old history after the initial inbox previews.
    // Preserve explicit unread flags, but don't alert for that initial backlog.
    if (read || !Object.prototype.hasOwnProperty.call(known, key))
      known[key] = !!read || (msg.createdAt > 0 && msg.createdAt < numberValue(initialReadBefore, 0))
  }
  next[conv.id] = known
  return next
}

// Migrate old cached unread flags using the freshest known conversation status.
function restoreLocalReadState(snapshot) {
  var row = objectValue(snapshot)
  var next = normalizeLocalReadState(row.localReadState)
  var latest = {}
  function consider(conversation, fetchedAt, fallbackState) {
    var conv = normalizeConversation(conversation)
    if (!isSafeConversationId(conv.id)) return
    if (conv.state === "") conv.state = fallbackState || ""
    if (conv.state === "") return
    var at = numberValue(fetchedAt, 0)
    if (!latest[conv.id] || at >= latest[conv.id].at)
      latest[conv.id] = { at: at, open: conversationIsOpen(conv) }
  }
  // Legacy waiting summaries omitted state, but came from the open-only query.
  var waiting = arrayValue(row.conversations)
  for (var i = 0; i < waiting.length; i++) consider(waiting[i], 0, "open")
  var inboxes = parseInboxCache(row.inboxes)
  for (var source in inboxes) {
    var snap = inboxes[source]
    for (var j = 0; j < snap.conversations.length; j++)
      consider(snap.conversations[j], snap.fetchedAt, source === "all" ? "" : source)
  }
  var threads = parseThreadCache(row.threads)
  for (var id in threads)
    consider(threads[id].conversation, threads[id].fetchedAt)
  for (var key in next) {
    if (!latest[key] || !latest[key].open) next = markConversationRead(next, key)
  }
  return next
}

// A successful Open inbox response contains every page, not just waiting threads.
function reconcileOpenReadState(value, conversations) {
  var next = normalizeLocalReadState(value)
  var open = {}
  var rows = arrayValue(conversations)
  for (var i = 0; i < rows.length; i++) {
    if (conversationIsOpen(rows[i])) open[rows[i].id] = true
  }
  for (var id in next) {
    if (!open[id]) next = markConversationRead(next, id)
  }
  return next
}

function localUnreadConversations(value) {
  var source = normalizeLocalReadState(value)
  var pending = {}
  for (var id in source) {
    for (var key in source[id]) {
      if (source[id][key] === false) {
        pending[id] = true
        break
      }
    }
  }
  return pending
}

// Inbox API pages are limited. Keep unread threads reachable even when they
// fall off that page; otherwise the tray can flash with nothing to read in it.
function includeUnreadConversations(conversations, lists, readState) {
  var rows = normalizeConversationList(conversations)
  var unread = localUnreadConversations(readState)
  var known = {}
  for (var i = 0; i < rows.length; i++) known[rows[i].id] = true
  var extra = {}
  var sources = arrayValue(lists)
  for (var s = 0; s < sources.length; s++) {
    var source = normalizeConversationList(sources[s])
    for (var j = 0; j < source.length; j++) {
      var row = source[j]
      if (!isSafeConversationId(row.id) || !unread[row.id] || known[row.id]) continue
      if (!extra[row.id]) extra[row.id] = row
      // Full thread responses supply the state omitted by waiting summaries.
      if (row.state !== "") extra[row.id].state = row.state
    }
  }
  var missing = []
  for (var id in extra) {
    if (Object.prototype.hasOwnProperty.call(extra, id) && conversationIsOpen(extra[id]))
      missing.push(extra[id])
  }
  missing.sort(function(a, b) { return b.updatedAt - a.updatedAt })
  return missing.concat(rows)
}

function pendingUrgentCount(pending) {
  var source = objectValue(pending)
  var n = 0
  for (var key in source) {
    if (!Object.prototype.hasOwnProperty.call(source, key)) continue
    if (!isSafeConversationId(key)) continue
    n += 1
  }
  return n
}

function conversationIndex(conversations) {
  var index = {}
  var source = arrayValue(conversations)
  for (var i = 0; i < source.length; i++) {
    var row = conversationFingerprint(source[i])
    if (row.id === "") continue
    index[row.id] = row
  }
  return index
}

function isNewWaitingMessage(previous, conv) {
  var row = conversationFingerprint(conv)
  if (row.id === "") return false
  var seen = objectValue(objectValue(previous)[row.id])
  if (textValue(seen.id) === "") return true
  return row.waitingSince > numberValue(seen.waitingSince, 0)
}

function newMessageConversations(previous, conversations) {
  var rows = []
  var source = arrayValue(conversations)
  for (var i = 0; i < source.length; i++) {
    if (!isNewWaitingMessage(previous, source[i])) continue
    rows.push(normalizeConversation(source[i]))
  }
  rows.sort(function(a, b) {
    var wait = numberValue(a.waitingSince, 0) - numberValue(b.waitingSince, 0)
    if (wait !== 0) return wait
    return numberValue(a.updatedAt, 0) - numberValue(b.updatedAt, 0)
  })
  return rows
}

function notificationLimit() {
  return 5
}

function notificationPreviewLimit() {
  return 120
}

function notificationsToSend(previous, conversations, limit) {
  var rows = newMessageConversations(previous, conversations)
  var cap = Math.max(0, Math.floor(numberValue(limit, notificationLimit())))
  if (cap <= 0 || rows.length <= cap) return rows
  return rows.slice(rows.length - cap)
}

function truncateText(value, limit) {
  var text = textValue(value).replace(/\s+/g, " ").trim()
  var cap = Math.max(0, Math.floor(numberValue(limit, notificationPreviewLimit())))
  if (cap <= 0) return ""
  if (text.length <= cap) return text
  if (cap === 1) return "…"
  return text.slice(0, cap - 1).replace(/\s+$/, "") + "…"
}

function notifySendText(value, fallback) {
  var text = textValue(value).replace(/\s+/g, " ").trim()
  if (text === "") text = textValue(fallback).replace(/\s+/g, " ").trim()
  if (text.charAt(0) === "-") text = "–" + text.slice(1)
  return text
}

function notificationHeadline(conv) {
  var row = objectValue(conv)
  var headline = notifySendText(row.from, "Intercom")
  return headline === "" ? "Intercom" : headline
}

function notificationBody(conv) {
  var row = objectValue(conv)
  var body = notifySendText(row.snippet, row.title)
  return truncateText(body, notificationPreviewLimit())
}

function shellQuote(value) {
  return "'" + textValue(value).replace(/'/g, "'\\''") + "'"
}

function notificationExec(conv) {
  var id = conversationId(conv)
  if (id === "") return "omarchy-shell omarchy-intercom-client open"
  return "omarchy-shell omarchy-intercom-client conversation " + shellQuote(id)
}

function notificationCommand(conv) {
  var command = [
    "omarchy-notification-send",
    "--app-name", "Intercom",
    "-u", "normal",
    "-g", GLYPH,
    "--exec", notificationExec(conv),
    notificationHeadline(conv)
  ]
  var body = notificationBody(conv)
  if (body !== "") command.push(body)
  return command
}

function queuedThreadAfterInFlight(loadingId, queuedId, queuedForce, requestedId, force) {
  var loading = textValue(loadingId)
  var queued = textValue(queuedId)
  var requested = textValue(requestedId)
  var refresh = !!force
  if (requested === "")
    return { id: "", force: false }
  if (loading === requested) {
    if (refresh && (queued === "" || queued === requested))
      return { id: requested, force: true }
    return { id: queued, force: queued !== "" && !!queuedForce }
  }
  return { id: requested, force: refresh }
}

function prefetchThreadIds(conversations, priorityId, cache, nowMs, ttlMs, force) {
  var source = arrayValue(conversations)
  var seen = {}
  var ids = []
  function consider(id) {
    id = textValue(id)
    if (id === "" || seen[id]) return
    seen[id] = true
    if (!force && cachedThreadFresh(readCachedThread(cache, id), nowMs, ttlMs))
      return
    ids.push(id)
  }
  consider(priorityId)
  for (var i = 0; i < source.length; i++)
    consider(conversationId(source[i]))
  return ids
}

var SCHEDULE_DEFAULT_HOUR = 9
var SCHEDULE_MORNING_HOUR = 9
var SCHEDULE_AFTERNOON_HOUR = 13
var SCHEDULE_EVENING_HOUR = 18
var SCHEDULE_NIGHT_HOUR = 21
var SCHEDULE_WEEKDAYS = {
  sunday: 0, sun: 0,
  monday: 1, mon: 1,
  tuesday: 2, tue: 2, tues: 2,
  wednesday: 3, wed: 3, weds: 3,
  thursday: 4, thu: 4, thur: 4, thurs: 4,
  friday: 5, fri: 5,
  saturday: 6, sat: 6
}
var SCHEDULE_MONTHS = {
  january: 0, jan: 0,
  february: 1, feb: 1,
  march: 2, mar: 2,
  april: 3, apr: 3,
  may: 4,
  june: 5, jun: 5,
  july: 6, jul: 6,
  august: 7, aug: 7,
  september: 8, sep: 8, sept: 8,
  october: 9, oct: 9,
  november: 10, nov: 10,
  december: 11, dec: 11
}

function pad2(value) {
  var n = Math.floor(numberValue(value, 0))
  if (n < 0) n = 0
  return (n < 10 ? "0" : "") + String(n)
}

function dateFormatMonthFirst(format) {
  var fmt = textValue(format)
  if (fmt === "") return localeMonthFirst()
  var monthAt = fmt.search(/M/)
  var dayAt = fmt.search(/d/i)
  if (monthAt >= 0 && dayAt >= 0) return monthAt < dayAt
  return localeMonthFirst()
}

function localeMonthFirst(localeName) {
  try {
    var locale = textValue(localeName)
    var fmt = locale === ""
      ? new Intl.DateTimeFormat(undefined, { year: "numeric", month: "numeric", day: "numeric" })
      : new Intl.DateTimeFormat(locale, { year: "numeric", month: "numeric", day: "numeric" })
    var parts = fmt.formatToParts(new Date(2020, 10, 21))
    var monthAt = -1
    var dayAt = -1
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].type === "month") monthAt = i
      else if (parts[i].type === "day") dayAt = i
    }
    if (monthAt >= 0 && dayAt >= 0) return monthAt < dayAt
  } catch (error) {}
  return false
}

function formatScheduleTime(ms, localeName) {
  var at = numberValue(ms, 0)
  if (at <= 0) return ""
  try {
    var locale = textValue(localeName)
    return new Date(at).toLocaleString(locale === "" ? undefined : locale, {
      weekday: "short",
      month: "short",
      day: "numeric",
      year: "numeric",
      hour: "numeric",
      minute: "2-digit"
    })
  } catch (error) {
    return new Date(at).toString()
  }
}

function emptyScheduleParse(error) {
  return { ok: false, at: 0, error: textValue(error, "Could not understand that date."), label: "" }
}

function okScheduleParse(at) {
  var when = numberValue(at, 0)
  if (when <= 0) return emptyScheduleParse("Could not understand that date.")
  return { ok: true, at: when, error: "", label: formatScheduleTime(when) }
}

function scheduleHourForPeriod(period) {
  if (period === "afternoon") return SCHEDULE_AFTERNOON_HOUR
  if (period === "evening") return SCHEDULE_EVENING_HOUR
  if (period === "night") return SCHEDULE_NIGHT_HOUR
  if (period === "noon") return 12
  if (period === "midnight") return 0
  if (period === "morning") return SCHEDULE_MORNING_HOUR
  return SCHEDULE_DEFAULT_HOUR
}

function validLocalDate(year, month, day) {
  var date = new Date(year, month, day)
  return date.getFullYear() === year && date.getMonth() === month && date.getDate() === day
}

function localDateMs(year, month, day, hour, minute) {
  return new Date(year, month, day, hour, minute, 0, 0).getTime()
}

function upcomingWeekdayMs(weekday, hour, minute, now, skipToday) {
  var wanted = Math.floor(numberValue(weekday, -1))
  if (wanted < 0 || wanted > 6) return 0
  var delta = (wanted - now.getDay() + 7) % 7
  if (delta === 0 && skipToday) delta = 7
  var at = localDateMs(now.getFullYear(), now.getMonth(), now.getDate() + delta, hour, minute)
  if (at <= now.getTime()) at = localDateMs(now.getFullYear(), now.getMonth(), now.getDate() + 7, hour, minute)
  return at
}

function upcomingMonthDayMs(month, day, hour, minute, now) {
  var year = now.getFullYear()
  for (var i = 0; i < 8; i++) {
    var candidate = year + i
    if (!validLocalDate(candidate, month, day)) continue
    var at = localDateMs(candidate, month, day, hour, minute)
    if (at > now.getTime()) return at
  }
  return 0
}

function resolveMonthDay(first, second, monthFirst) {
  var a = Math.floor(numberValue(first, 0))
  var b = Math.floor(numberValue(second, 0))
  if (a < 1 || b < 1) return null
  var month
  var day
  if (a > 12 && b > 12) return null
  if (a > 12) {
    day = a
    month = b
  } else if (b > 12) {
    month = a
    day = b
  } else if (monthFirst) {
    month = a
    day = b
  } else {
    day = a
    month = b
  }
  if (month < 1 || month > 12 || day < 1 || day > 31) return null
  return { month: month - 1, day: day }
}

function expandYear(value) {
  var year = Math.floor(numberValue(value, 0))
  if (year < 0) return 0
  if (year < 100) return year >= 70 ? 1900 + year : 2000 + year
  return year
}

function parseClockHour(hourText, minuteText, meridian) {
  var hour = Math.floor(numberValue(hourText, -1))
  var minute = minuteText === undefined || minuteText === null || minuteText === ""
    ? 0
    : Math.floor(numberValue(minuteText, -1))
  if (hour < 0 || hour > 23 || minute < 0 || minute > 59) return null
  var mark = textValue(meridian).toLowerCase().replace(/\./g, "")
  if (mark === "am" || mark === "pm") {
    if (hour < 1 || hour > 12) return null
    if (mark === "am") hour = hour === 12 ? 0 : hour
    else hour = hour === 12 ? 12 : hour + 12
  }
  return { hour: hour, minute: minute }
}

function takeMatch(text, pattern) {
  var match = textValue(text).match(pattern)
  if (!match) return null
  var rest = (textValue(text).slice(0, match.index) + " " + textValue(text).slice(match.index + match[0].length))
    .replace(/\s+/g, " ")
    .replace(/^\s+|\s+$/g, "")
  return { match: match, rest: rest }
}

function parseRelativeDuration(text, nowAt) {
  var match = textValue(text).match(/^in\s+(\d+)\s*(minutes?|mins?|m|hours?|hrs?|h|days?|d|weeks?|w)$/)
  if (!match) return null
  var amount = Math.floor(numberValue(match[1], 0))
  if (amount <= 0) return emptyScheduleParse("That time is in the past.")
  var unit = match[2].charAt(0)
  var ms = 0
  if (unit === "m") ms = amount * 60 * 1000
  else if (unit === "h") ms = amount * 60 * 60 * 1000
  else if (unit === "d") ms = amount * 24 * 60 * 60 * 1000
  else if (unit === "w") ms = amount * 7 * 24 * 60 * 60 * 1000
  var at = numberValue(nowAt, Date.now()) + ms
  if (at <= numberValue(nowAt, Date.now())) return emptyScheduleParse("That time is in the past.")
  return okScheduleParse(at)
}

function parseScheduleText(text, nowMs, options) {
  var nowAt = numberValue(nowMs, Date.now())
  var now = new Date(nowAt)
  if (!isFinite(now.getTime())) {
    nowAt = Date.now()
    now = new Date(nowAt)
  }
  var opts = objectValue(options)
  var monthFirst = opts.monthFirst !== undefined ? opts.monthFirst === true : dateFormatMonthFirst(opts.dateFormat)
  var source = textValue(text).replace(/,/g, " ").replace(/\s+/g, " ").replace(/^\s+|\s+$/g, "")
  if (source === "") return emptyScheduleParse("Enter a date or time.")
  var lower = source.toLowerCase()
  if (/\byesterday\b/.test(lower) || /\blast\s+(night|week|month|year|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b/.test(lower))
    return emptyScheduleParse("That time is in the past.")

  var relative = parseRelativeDuration(lower, nowAt)
  if (relative) return relative

  var rest = lower
  var thisPeriod = false
  if (/^this\s+/.test(rest)) {
    thisPeriod = true
    rest = rest.replace(/^this\s+/, "")
  }
  var nextWeekday = false
  if (/^next\s+/.test(rest)) {
    nextWeekday = true
    rest = rest.replace(/^next\s+/, "")
  }

  var tonight = false
  var taken = takeMatch(rest, /\btonight\b/)
  if (taken) {
    tonight = true
    rest = taken.rest
  }

  var dayOffset = null
  taken = takeMatch(rest, /\btomorrow\b/)
  if (taken) {
    dayOffset = 1
    rest = taken.rest
  } else {
    taken = takeMatch(rest, /\btoday\b/)
    if (taken) {
      dayOffset = 0
      rest = taken.rest
    }
  }

  var weekday = null
  taken = takeMatch(rest, /\b(monday|mon|tuesday|tue|tues|wednesday|wed|weds|thursday|thu|thur|thurs|friday|fri|saturday|sat|sunday|sun)\b/)
  if (taken) {
    weekday = SCHEDULE_WEEKDAYS[taken.match[1]]
    rest = taken.rest
  }

  var year = null
  var month = null
  var day = null
  taken = takeMatch(rest, /\b(\d{4})-(\d{1,2})-(\d{1,2})\b/)
  if (taken) {
    year = expandYear(taken.match[1])
    month = Math.floor(numberValue(taken.match[2], 0)) - 1
    day = Math.floor(numberValue(taken.match[3], 0))
    rest = taken.rest
  } else {
    taken = takeMatch(rest, /\b(january|jan|february|feb|march|mar|april|apr|may|june|jun|july|jul|august|aug|september|sep|sept|october|oct|november|nov|december|dec)\s+(\d{1,2})(?:st|nd|rd|th)?(?:\s+(\d{2,4}))?\b/)
    if (taken) {
      month = SCHEDULE_MONTHS[taken.match[1]]
      day = Math.floor(numberValue(taken.match[2], 0))
      if (taken.match[3]) year = expandYear(taken.match[3])
      rest = taken.rest
    } else {
      taken = takeMatch(rest, /\b(\d{1,2})(?:st|nd|rd|th)?\s+(january|jan|february|feb|march|mar|april|apr|may|june|jun|july|jul|august|aug|september|sep|sept|october|oct|november|nov|december|dec)(?:\s+(\d{2,4}))?\b/)
      if (taken) {
        day = Math.floor(numberValue(taken.match[1], 0))
        month = SCHEDULE_MONTHS[taken.match[2]]
        if (taken.match[3]) year = expandYear(taken.match[3])
        rest = taken.rest
      } else {
        taken = takeMatch(rest, /\b(\d{1,2})[/-](\d{1,2})(?:[/-](\d{2,4}))?\b/)
        if (taken) {
          var resolved = resolveMonthDay(taken.match[1], taken.match[2], monthFirst)
          if (!resolved) return emptyScheduleParse("Could not understand that date.")
          month = resolved.month
          day = resolved.day
          if (taken.match[3]) year = expandYear(taken.match[3])
          rest = taken.rest
        }
      }
    }
  }

  var period = null
  taken = takeMatch(rest, /\b(morning|afternoon|evening|night|noon|midnight)\b/)
  if (taken) {
    period = taken.match[1]
    rest = taken.rest
  } else if (tonight) {
    period = "night"
  }

  var hour = null
  var minute = 0
  var hadTime = false
  var clock = null
  taken = takeMatch(rest, /\b(\d{1,2}):(\d{2})\s*(a\.?m\.?|p\.?m\.?)?\b/)
  if (taken) {
    clock = parseClockHour(taken.match[1], taken.match[2], taken.match[3])
    if (!clock) return emptyScheduleParse("Could not understand that date.")
    hour = clock.hour
    minute = clock.minute
    hadTime = true
    rest = taken.rest
  } else {
    taken = takeMatch(rest, /\b(\d{1,2})\s*(a\.?m\.?|p\.?m\.?)\b/)
    if (taken) {
      clock = parseClockHour(taken.match[1], 0, taken.match[2])
      if (!clock) return emptyScheduleParse("Could not understand that date.")
      hour = clock.hour
      minute = clock.minute
      hadTime = true
      rest = taken.rest
    } else {
      taken = takeMatch(rest, /\bat\s+(\d{1,2})\b/)
      if (taken) {
        clock = parseClockHour(taken.match[1], 0, "")
        if (!clock) return emptyScheduleParse("Could not understand that date.")
        hour = clock.hour
        minute = clock.minute
        hadTime = true
        rest = taken.rest
      }
    }
  }

  rest = rest.replace(/\b(at|on|the|around)\b/g, " ").replace(/\s+/g, " ").replace(/^\s+|\s+$/g, "")
  if (rest !== "") {
    taken = rest.match(/^(\d{1,2})$/)
    if (taken && !hadTime) {
      clock = parseClockHour(taken[1], 0, "")
      if (!clock) return emptyScheduleParse("Could not understand that date.")
      hour = clock.hour
      minute = clock.minute
      hadTime = true
      rest = ""
    }
  }
  if (rest !== "") return emptyScheduleParse("Could not understand that date.")

  if (hour === null) {
    if (period) hour = scheduleHourForPeriod(period)
    else hour = SCHEDULE_DEFAULT_HOUR
    minute = 0
  }

  var hasCalendar = month !== null && day !== null
  if (year !== null && !hasCalendar) return emptyScheduleParse("Could not understand that date.")
  if (hasCalendar && (month < 0 || month > 11 || day < 1 || day > 31))
    return emptyScheduleParse("Could not understand that date.")
  if (year !== null && hasCalendar && !validLocalDate(year, month, day))
    return emptyScheduleParse("Could not understand that date.")

  var at = 0
  if (hasCalendar && year !== null) {
    at = localDateMs(year, month, day, hour, minute)
  } else if (hasCalendar) {
    at = upcomingMonthDayMs(month, day, hour, minute, now)
  } else if (weekday !== null) {
    at = upcomingWeekdayMs(weekday, hour, minute, now, nextWeekday)
  } else if (dayOffset !== null) {
    at = localDateMs(now.getFullYear(), now.getMonth(), now.getDate() + dayOffset, hour, minute)
  } else {
    at = localDateMs(now.getFullYear(), now.getMonth(), now.getDate(), hour, minute)
  }

  if (at <= 0) return emptyScheduleParse("Could not understand that date.")

  if (at <= nowAt) {
    if (thisPeriod || (tonight && dayOffset === null && weekday === null && !hasCalendar && !hadTime))
      at = nowAt + 60 * 60 * 1000
    else if (!hasCalendar && weekday === null && dayOffset === null && !tonight)
      at = localDateMs(now.getFullYear(), now.getMonth(), now.getDate() + 1, hour, minute)
    else if (weekday !== null && !nextWeekday)
      at = localDateMs(now.getFullYear(), now.getMonth(), now.getDate() + 7, hour, minute)
    else if (hasCalendar && year === null)
      at = upcomingMonthDayMs(month, day, hour, minute, now)
  }

  if (at <= nowAt) return emptyScheduleParse("That time is in the past.")
  return okScheduleParse(at)
}

function weekdayOrder(weekStart) {
  var start = Math.floor(numberValue(weekStart, 1))
  if (start < 0 || start > 6) start = 1
  var out = []
  for (var i = 0; i < 7; i++) out.push((start + i) % 7)
  return out
}

function monthCells(year, month, weekStart) {
  var y = Math.floor(numberValue(year, 0))
  var m = Math.floor(numberValue(month, 0))
  var start = Math.floor(numberValue(weekStart, 1))
  if (start < 0 || start > 6) start = 1
  var leading = (new Date(y, m, 1).getDay() - start + 7) % 7
  var cursor = new Date(y, m, 1 - leading)
  var weeks = []
  for (var w = 0; w < 6; w++) {
    var days = []
    for (var d = 0; d < 7; d++) {
      days.push({
        year: cursor.getFullYear(),
        month: cursor.getMonth(),
        day: cursor.getDate(),
        inMonth: cursor.getMonth() === m && cursor.getFullYear() === y
      })
      cursor.setDate(cursor.getDate() + 1)
    }
    weeks.push(days)
  }
  return weeks
}

function stepMonth(year, month, delta) {
  var target = new Date(Math.floor(numberValue(year, 0)), Math.floor(numberValue(month, 0)) + Math.floor(numberValue(delta, 0)), 1)
  return { year: target.getFullYear(), month: target.getMonth() }
}

function pickerDateMs(year, month, day, hour, minute) {
  var y = Math.floor(numberValue(year, 0))
  var m = Math.floor(numberValue(month, 0))
  var d = Math.floor(numberValue(day, 0))
  var h = Math.floor(numberValue(hour, SCHEDULE_DEFAULT_HOUR))
  var min = Math.floor(numberValue(minute, 0))
  if (m < 0 || m > 11 || d < 1 || d > 31 || h < 0 || h > 23 || min < 0 || min > 59)
    return emptyScheduleParse("Choose a valid date and time.")
  if (!validLocalDate(y, m, d)) return emptyScheduleParse("Choose a valid date and time.")
  var at = localDateMs(y, m, d, h, min)
  return at
}

function parsePickerDate(year, month, day, hour, minute, nowMs) {
  var at = pickerDateMs(year, month, day, hour, minute)
  if (typeof at === "object") return at
  if (at <= numberValue(nowMs, Date.now())) return emptyScheduleParse("That time is in the past.")
  return okScheduleParse(at)
}

function normalizeScheduledEntry(value) {
  var row = objectValue(value)
  var id = textValue(row.id)
  var conversation = textValue(row.conversationId)
  var body = textValue(row.body)
  var attachments = localAttachments(row.attachments)
  var sendAt = Math.floor(numberValue(row.sendAt, 0))
  if (id === "" || !isSafeConversationId(conversation) || (body.trim() === "" && !attachments.length) || sendAt <= 0)
    return null
  var entry = {
    id: id,
    conversationId: conversation,
    body: body,
    note: row.note === true,
    sendAt: sendAt
  }
  if (attachments.length) entry.attachments = attachments
  return entry
}

function normalizeScheduled(value) {
  var source = arrayValue(value)
  var rows = []
  var seen = {}
  for (var i = 0; i < source.length; i++) {
    var row = normalizeScheduledEntry(source[i])
    if (!row || seen[row.id]) continue
    seen[row.id] = true
    rows.push(row)
  }
  rows.sort(function(a, b) {
    if (a.sendAt !== b.sendAt) return a.sendAt - b.sendAt
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0
  })
  return rows
}

function parseScheduled(raw) {
  var text = textValue(raw).trim()
  if (text === "") return []
  try {
    var parsed = JSON.parse(text)
  } catch (error) {
    return []
  }
  return normalizeScheduled(parsed)
}

function scheduledId(nowMs, existing) {
  var prefix = "s" + String(Math.floor(numberValue(nowMs, Date.now())))
  var id = prefix
  var n = 0
  var rows = arrayValue(existing)
  function taken(wanted) {
    for (var i = 0; i < rows.length; i++) {
      if (textValue((rows[i] || {}).id) === wanted) return true
    }
    return false
  }
  while (taken(id)) {
    n += 1
    id = prefix + "-" + n
  }
  return id
}

function addScheduled(list, conversationId, body, note, sendAt, nowMs, attachments) {
  var rows = normalizeScheduled(list)
  var conversation = textValue(conversationId)
  var text = textValue(body)
  var at = Math.floor(numberValue(sendAt, 0))
  var files = localAttachments(attachments)
  if (!isSafeConversationId(conversation) || (text.trim() === "" && !files.length) || at <= 0) return rows
  rows.push({
    id: scheduledId(nowMs, rows),
    conversationId: conversation,
    body: text,
    note: note === true,
    sendAt: at,
    attachments: files
  })
  return normalizeScheduled(rows)
}

function removeScheduled(list, scheduledIdValue) {
  var wanted = textValue(scheduledIdValue)
  var rows = normalizeScheduled(list)
  if (wanted === "") return rows
  var next = []
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].id === wanted) continue
    next.push(rows[i])
  }
  return next
}

function dueScheduled(list, nowMs) {
  var now = numberValue(nowMs, Date.now())
  var rows = normalizeScheduled(list)
  var due = []
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].sendAt <= now) due.push(rows[i])
  }
  return due
}

function scheduledForConversation(list, conversationId) {
  var wanted = textValue(conversationId)
  var rows = normalizeScheduled(list)
  if (!isSafeConversationId(wanted)) return []
  var matches = []
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].conversationId === wanted) matches.push(rows[i])
  }
  return matches
}

function hasScheduled(list, conversationId) {
  return scheduledForConversation(list, conversationId).length > 0
}

function findScheduled(list, scheduledIdValue) {
  var wanted = textValue(scheduledIdValue)
  var rows = normalizeScheduled(list)
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].id === wanted) return rows[i]
  }
  return null
}

function threadFocusKeyFor(kind, id, index) {
  var type = textValue(kind)
  if (type === "draft") return "draft"
  if (type === "draft-action") return "draft-action"
  if (type === "scheduled") return "scheduled:" + textValue(id)
  if (type === "scheduled-action") return "scheduled-action:" + textValue(id)
  var msgId = textValue(id)
  if (msgId !== "") return "message:" + msgId
  return "message:#" + String(Math.max(0, Math.floor(numberValue(index, 0))))
}

function threadFocusItem(kind, id, index) {
  return {
    kind: textValue(kind),
    id: textValue(id),
    index: Math.max(0, Math.floor(numberValue(index, 0))),
    key: threadFocusKeyFor(kind, id, index)
  }
}

function isThreadMessageKind(kind) {
  var type = textValue(kind)
  return type === "message" || type === "draft" || type === "scheduled"
}

function threadFocusItems(messages, showDraft, scheduled) {
  var items = []
  var source = arrayValue(messages)
  for (var i = 0; i < source.length; i++) {
    var msg = objectValue(source[i])
    items.push(threadFocusItem("message", msg.id, i))
  }
  if (showDraft) {
    items.push(threadFocusItem("draft", "", 0))
    items.push(threadFocusItem("draft-action", "", 0))
  }
  var queued = arrayValue(scheduled)
  for (var j = 0; j < queued.length; j++) {
    var sid = textValue(objectValue(queued[j]).id)
    items.push(threadFocusItem("scheduled", sid, j))
    items.push(threadFocusItem("scheduled-action", sid, j))
  }
  return items
}

function lastThreadMessageIndex(items) {
  var rows = arrayValue(items)
  var last = -1
  for (var i = 0; i < rows.length; i++) {
    if (isThreadMessageKind(objectValue(rows[i]).kind)) last = i
  }
  return last
}

function resolveThreadFocus(items, key, index, preferLastMessage) {
  var rows = arrayValue(items)
  if (rows.length === 0) return { index: -1, key: "" }
  var wanted = textValue(key)
  if (wanted !== "") {
    for (var i = 0; i < rows.length; i++) {
      if (textValue(objectValue(rows[i]).key) === wanted)
        return { index: i, key: wanted }
    }
  }
  var idx = Math.floor(numberValue(index, -1))
  if (idx >= 0) {
    idx = Math.max(0, Math.min(rows.length - 1, idx))
    return { index: idx, key: textValue(objectValue(rows[idx]).key) }
  }
  if (preferLastMessage) {
    var last = lastThreadMessageIndex(rows)
    if (last < 0) last = rows.length - 1
    return { index: last, key: textValue(objectValue(rows[last]).key) }
  }
  return { index: -1, key: "" }
}

function moveThreadFocus(items, key, index, delta) {
  var rows = arrayValue(items)
  if (rows.length === 0) return { index: -1, key: "" }
  var step = Math.floor(numberValue(delta, 0))
  if (step === 0) return resolveThreadFocus(rows, key, index, false)
  var current = -1
  var wanted = textValue(key)
  if (wanted !== "") {
    for (var i = 0; i < rows.length; i++) {
      if (textValue(objectValue(rows[i]).key) === wanted) {
        current = i
        break
      }
    }
  }
  if (current < 0) {
    var idx = Math.floor(numberValue(index, -1))
    if (idx >= 0 && idx < rows.length) current = idx
  }
  if (current < 0) current = step > 0 ? -1 : rows.length
  var next = Math.max(0, Math.min(rows.length - 1, current + step))
  return { index: next, key: textValue(objectValue(rows[next]).key) }
}
