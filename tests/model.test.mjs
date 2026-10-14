import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const source = fs.readFileSync(new URL("../Model.js", import.meta.url), "utf8")
  .replace(/^\.pragma library\s*/u, "");
const model = { console, Date, JSON, Object, Array, Number, String, Math, isFinite };
vm.createContext(model);
vm.runInContext(source, model, { filename: "Model.js" });

const firstMessage = { id: "m1", kind: "customer", createdAt: 100, body: "Hello" };
const secondMessage = { id: "m2", kind: "customer", createdAt: 100, body: "Follow-up" };
const localThread = { id: "local", waitingSince: 100, messages: [firstMessage] };
let localReads = model.updateLocalReadState({}, localThread, false);
assert.equal(model.pendingUrgentCount(model.localUnreadConversations(localReads)), 1);
localReads = model.updateLocalReadState(localReads, localThread, true);
assert.equal(model.pendingUrgentCount(model.localUnreadConversations(localReads)), 0);
// A follow-up is unread even when Intercom's waiting timestamp has not changed.
localReads = model.updateLocalReadState(localReads, { ...localThread, messages: [firstMessage, secondMessage] }, false);
assert.equal(localReads.local.$m1, true);
assert.equal(localReads.local.$m2, false);
// A stale displayed thread cannot acknowledge a message it doesn't contain.
localReads = model.updateLocalReadState(localReads, localThread, true);
assert.equal(localReads.local.$m2, false);
// Disappearing from the waiting list / being closed doesn't discard unread state.
localReads = model.updateLocalReadState(localReads, { id: "local", state: "closed", messages: [] }, false);
assert.equal(localReads.local.$m2, false);
const restoredReads = model.parseDiskCache(model.serializeDiskCache({
  state: "ready", localReadState: localReads
})).localReadState;
assert.equal(restoredReads.local.$m1, true);
assert.equal(restoredReads.local.$m2, false);
localReads = model.updateLocalReadState(restoredReads, { ...localThread, messages: [secondMessage] }, true);
assert.equal(model.pendingUrgentCount(model.localUnreadConversations(localReads)), 0);
localReads = model.updateLocalReadState(localReads, { id: "local", messages: [
  { id: "mine", kind: "teammate", email: "me@example.com", body: "My reply" },
  { id: "note", kind: "note", email: "me@example.com", body: "My note" }
] }, false, "me@example.com");
assert.equal(model.pendingUrgentCount(model.localUnreadConversations(localReads)), 0);
localReads = model.updateLocalReadState(localReads, { id: "local", messages: [
  { id: "other", kind: "teammate", email: "other@example.com", body: "Another teammate" }
] }, false, "me@example.com");
assert.equal(localReads.local.$other, false);
assert.equal(model.messageUnread(localReads, "local", { id: "other" }), true);
assert.equal(model.messageUnread(localReads, "local", firstMessage), false);
assert.equal(model.messageUnread(localReads, "missing", firstMessage), false);

// Focusing one card clears only its dot, and urgency lasts until the last unread card.
let focusedReads = model.updateLocalReadState({}, {
  id: "cards", messages: [firstMessage, secondMessage]
}, false);
focusedReads = model.updateLocalReadState(focusedReads, { id: "cards", messages: [firstMessage] }, true);
assert.equal(model.messageUnread(focusedReads, "cards", firstMessage), false);
assert.equal(model.messageUnread(focusedReads, "cards", secondMessage), true);
assert.equal(model.pendingUrgentCount(model.localUnreadConversations(focusedReads)), 1);
focusedReads = model.updateLocalReadState(focusedReads, { id: "cards", messages: [secondMessage] }, true);
assert.equal(model.messageUnread(focusedReads, "cards", secondMessage), false);
assert.equal(model.pendingUrgentCount(model.localUnreadConversations(focusedReads)), 0);

const anonymousMessage = { createdAt: 100, kind: "customer", from: "Customer", body: "No ID" };
let anonymousReads = model.updateLocalReadState({}, { id: "cards", messages: [anonymousMessage] }, false);
assert.equal(model.messageUnread(anonymousReads, "cards", anonymousMessage), true);
anonymousReads = model.updateLocalReadState(anonymousReads, { id: "cards", messages: [anonymousMessage] }, true);
assert.equal(model.messageUnread(anonymousReads, "cards", anonymousMessage), false);

// Highlighting a conversation marks all its messages read, but not other threads.
let highlightedReads = model.updateLocalReadState({}, {
  id: "highlighted", messages: [firstMessage, secondMessage]
}, false);
highlightedReads = model.updateLocalReadState(highlightedReads, { id: "other-thread", messages: [firstMessage] }, false);
const beforeHighlight = highlightedReads;
highlightedReads = model.markConversationRead(highlightedReads, "highlighted");
assert.equal(model.messageUnread(highlightedReads, "highlighted", firstMessage), false);
assert.equal(model.messageUnread(highlightedReads, "highlighted", secondMessage), false);
assert.equal(model.messageUnread(highlightedReads, "other-thread", firstMessage), true);
assert.equal(model.messageUnread(beforeHighlight, "highlighted", firstMessage), true);
highlightedReads = model.markConversationRead(highlightedReads, "other-thread");
assert.equal(model.pendingUrgentCount(model.localUnreadConversations(highlightedReads)), 0);

// A locally unread thread outside the limited inbox page must remain reachable.
const page = [{ id: "recent", state: "open", updatedAt: 200 }];
const oldThreads = [
  { id: "older", state: "open", updatedAt: 100, messages: [firstMessage, secondMessage] },
  { id: "closed-unread", state: "closed", updatedAt: 50, messages: [firstMessage] },
  { id: "already-read", state: "open", messages: [firstMessage] }
];
let pageReads = {};
for (const thread of oldThreads) {
  pageReads = model.updateLocalReadState(pageReads, thread, thread.id === "already-read");
}
let reachable = model.includeUnreadConversations(page, [oldThreads, oldThreads], pageReads);
assert.deepEqual(Array.from(reachable, row => row.id), ["older", "closed-unread", "recent"]);
assert.deepEqual(Array.from(model.filterInbox(reachable, "open"), row => row.id), ["older", "recent"]);
assert.deepEqual(Array.from(model.filterInbox(reachable, "closed"), row => row.id), ["closed-unread"]);
assert.equal(model.resolveInboxSelection(reachable, "open", "older", 1).index, 0);
pageReads = model.updateLocalReadState(pageReads, { id: "older", messages: [firstMessage] }, true);
reachable = model.includeUnreadConversations(page, [oldThreads], pageReads);
assert.equal(reachable[0].id, "older");
pageReads = model.updateLocalReadState(pageReads, oldThreads[0], true);
reachable = model.includeUnreadConversations(page, [oldThreads], pageReads);
assert.deepEqual(Array.from(reachable, row => row.id), ["closed-unread", "recent"]);
// The full thread state takes precedence over summaries missing a state.
reachable = model.includeUnreadConversations(page, [
  [{ id: "closed-unread", state: "", updatedAt: 50 }],
  [oldThreads[1]]
], pageReads);
assert.equal(reachable[0].state, "closed");
assert.equal(model.filterInbox(reachable, "open").length, 1);
assert.equal(JSON.stringify(model.normalizeLocalReadState({ bad: { "$m": "false", "$n": false } })),
  JSON.stringify({ bad: { "$n": false } }));

const empty = model.parseFetch("");
assert.equal(empty.state, "error");
assert.equal(empty.waitingCount, 0);
assert.equal(empty.viewed, "");

const malformed = model.parseFetch("not-json");
assert.equal(malformed.state, "error");

const unconfigured = model.parseFetch(JSON.stringify({
  state: "unconfigured",
  message: "Add an Intercom access token to /tmp/token",
  waitingCount: 0,
  inboxUrl: "",
  conversations: []
}));
assert.equal(unconfigured.state, "unconfigured");
assert.match(unconfigured.message, /access token/);
assert.equal(model.parseFetch(JSON.stringify({
  state: "saved",
  message: "Saved token to /tmp/token",
  waitingCount: 0,
  inboxUrl: "",
  conversations: []
})).state, "saved");

const ready = model.parseFetch(JSON.stringify({
  state: "ready",
  message: "",
  waitingCount: 3,
  inboxUrl: "https://app.eu.intercom.com/a/inbox/abc/inbox/shared/all",
  workspaceId: "abc",
  conversations: [
    {
      id: "1295",
      title: "Billing question",
      snippet: "Please help",
      from: "Ada Lovelace",
      email: "ada@example.com",
      url: "https://app.eu.intercom.com/a/inbox/abc/inbox/shared/all/conversation/1295",
      waitingSince: 1700000000
    },
    { id: "", title: "skip me" }
  ]
}));
assert.equal(ready.state, "ready");
assert.equal(ready.waitingCount, 3);
assert.equal(ready.conversations.length, 1);
assert.equal(ready.conversations[0].id, "1295");
assert.equal(ready.conversations[0].from, "Ada Lovelace");
assert.equal(ready.conversations[0].email, "ada@example.com");
assert.equal(ready.inboxUrl, "https://app.eu.intercom.com/a/inbox/abc/inbox/shared/all");
assert.equal(ready.workspaceId, "abc");
assert.equal(ready.conversation.id, "");

const thread = model.parseFetch(JSON.stringify({
  state: "ready",
  message: "",
  waitingCount: 0,
  openCount: 4,
  conversation: {
    id: "1295",
    title: "Billing question",
    url: "https://app.intercom.com/a/inbox/abc/inbox/shared/all/conversation/1295",
    waitingSince: 1700000000,
    messages: [
      { id: "1", from: "Ada Lovelace", email: "ada@example.com", kind: "customer", createdAt: 100, body: "Help please" },
      { id: "2", from: "Bo", kind: "note", createdAt: 150, body: "Internal" },
      { id: "3", from: "Bo", kind: "teammate", createdAt: 200, body: "On it" },
      { id: "skip", from: "x", kind: "mystery", createdAt: 250, body: "" },
      { id: "4", from: "Bot", kind: "bot", createdAt: 260, body: "Ack" }
    ]
  }
}));
assert.equal(thread.conversation.id, "1295");
assert.equal(thread.openCount, 4);
assert.equal(thread.conversation.messages.length, 4);
assert.equal(thread.conversation.messages[0].kind, "customer");
assert.equal(thread.conversation.messages[0].from, "Ada Lovelace");
assert.equal(thread.conversation.messages[0].email, "ada@example.com");
assert.equal(thread.conversation.messages[1].kind, "note");
assert.equal(thread.conversation.messages[2].kind, "teammate");
assert.equal(thread.conversation.messages[3].kind, "bot");
assert.equal(model.normalizeMessage({ kind: "mystery", body: "x" }).kind, "customer");
assert.equal(thread.panel, "expanded");
assert.equal(model.panelMode("expanded"), "expanded");
assert.equal(model.panelMode("LARGE"), "large");
assert.equal(model.panelMode("nope"), "expanded");
assert.equal(model.panelMode("compact"), "expanded");
assert.equal(model.panelMode(""), "expanded");
assert.equal(model.parseFetch(JSON.stringify({
  state: "ready",
  panel: "compact",
  conversations: []
})).panel, "expanded");
assert.equal(model.parsePrefs(JSON.stringify({ panel: "compact" })).panel, "expanded");
assert.equal(model.nextPanelMode("compact"), "large");
assert.equal(model.nextPanelMode("expanded"), "large");
assert.equal(model.nextPanelMode("large"), "expanded");
assert.equal(model.parseFetch(JSON.stringify({
  state: "ready",
  panel: "expanded",
  conversations: []
})).panel, "expanded");
assert.equal(model.parseFetch(JSON.stringify({
  state: "ready",
  panel: "large",
  conversations: []
})).panel, "large");
assert.equal(model.parseFetch(JSON.stringify({
  state: "ready",
  filter: "waiting",
  conversations: []
})).filter, "waiting");
assert.equal(model.parseFetch(JSON.stringify({
  state: "ready",
  filter: "closed",
  conversations: []
})).filter, "closed");
assert.equal(model.parseFetch(JSON.stringify({
  state: "ready",
  filter: "snoozed",
  conversations: []
})).filter, "snoozed");
assert.equal(model.parseFetch(JSON.stringify({
  state: "ready",
  filter: "all",
  conversations: []
})).filter, "all");
assert.equal(model.parseFetch(JSON.stringify({
  state: "ready",
  filter: "nope",
  conversations: []
})).filter, "open");
assert.equal(model.parseFetch(JSON.stringify({
  state: "ready",
  conversations: []
})).hasInboxCounts, false);
const counted = model.parseFetch(JSON.stringify({
  state: "ready",
  waitingCount: 2,
  openCount: 10,
  closedCount: 4,
  snoozedCount: 1,
  allCount: 15,
  conversations: []
}));
assert.equal(counted.hasInboxCounts, true);
assert.equal(counted.openCount, 10);
assert.equal(counted.closedCount, 4);
assert.equal(counted.snoozedCount, 1);
assert.equal(counted.allCount, 15);
assert.equal(model.parseFetch(JSON.stringify({
  state: "ready",
  viewed: "1295",
  conversations: []
})).viewed, "1295");
assert.equal(model.parseFetch(JSON.stringify({
  state: "ready",
  viewed: "1295/other",
  conversations: []
})).viewed, "");
assert.equal(model.parseSyncStatus("").state, "");
assert.equal(model.parseSyncStatus(JSON.stringify({
  state: "syncing",
  message: "Syncing 12 of 40…",
  scanned: 12,
  stored: 4,
  skipped: 8,
  failed: 0,
  total: 40,
  syncedAt: 50
})).skipped, 8);
assert.equal(model.formatSyncProgress(true, 12, 40, ""), "Syncing 12 of 40…");
assert.equal(model.formatSyncProgress(true, 3, 0, ""), "Syncing 3 conversations…");
assert.equal(model.formatSyncProgress(false, 40, 40, "Synced 40 conversations."), "Synced 40 conversations.");
assert.equal(JSON.stringify(model.searchTokens("  Billing  Ada ")), JSON.stringify(["billing", "ada"]));
assert.equal(model.conversationMatchesQuery({
  id: "1",
  title: "Billing question",
  from: "Ada",
  email: "ada@example.com",
  snippet: "Please refund",
  messages: [{ body: "I was charged twice" }]
}, ["billing", "twice"]), true);
assert.equal(model.conversationMatchesQuery({
  title: "Billing",
  from: "Ada"
}, ["bo"]), false);
assert.equal(model.searchConversations([
  [{ id: "1", title: "Billing", from: "Ada" }, { id: "2", title: "Login", from: "Bo" }],
  [{ id: "3", title: "Old billing", state: "closed", snippet: "Thanks" }]
], "billing", 10).map(function(row) { return row.id; }).join(","), "1,3");
assert.equal(model.mergeSearchHits(
  [{ id: "1", title: "A" }],
  [{ id: "1", title: "A" }, { id: "2", title: "B" }],
  10
).map(function(row) { return row.id; }).join(","), "1,2");
assert.equal(model.archiveIndexConversations({
  "1295": { id: "1295", title: "Hi", from: "Ada" }
})[0].title, "Hi");
assert.equal(model.filterInbox([
  { id: "1", waitingSince: 10 },
  { id: "2", waitingSince: 0 },
  { id: "3", waitingSince: 20 }
], false).length, 3);
const waitingOnly = model.filterInbox([
  { id: "1", waitingSince: 10 },
  { id: "2", waitingSince: 0 },
  { id: "3", waitingSince: 20 }
], true);
assert.equal(waitingOnly.length, 2);
assert.equal(waitingOnly[0].id, "1");
assert.equal(waitingOnly[1].id, "3");
assert.equal(model.inboxFilterMode("closed"), "closed");
assert.equal(model.inboxFilterMode("SNOOZED"), "snoozed");
assert.equal(model.inboxFetchFilter("waiting"), "open");
assert.equal(model.inboxFetchFilter("closed"), "closed");
assert.equal(model.parsePrefs("").panel, "expanded");
assert.equal(model.parsePrefs("not-json").filter, "open");
assert.equal(model.parsePrefs(JSON.stringify({
  panel: "expanded",
  filter: "closed",
  viewed: "1295",
  region: "US"
})).panel, "expanded");
assert.equal(model.parsePrefs(JSON.stringify({
  panel: "expanded",
  filter: "WAITING",
  viewed: "1295"
})).filter, "waiting");
assert.equal(model.parsePrefs(JSON.stringify({
  panel: "expanded",
  filter: "closed",
  viewed: "1295"
})).viewed, "1295");
assert.equal(model.parsePrefs(JSON.stringify({ panel: "nope", viewed: "../x" })).panel, "expanded");
assert.equal(model.parsePrefs(JSON.stringify({ panel: "large" })).panel, "large");
assert.equal(model.parsePrefs(JSON.stringify({ viewed: "../x" })).viewed, "");
assert.equal(model.filterChordKey("o"), "open");
assert.equal(model.filterChordKey("W"), "waiting");
assert.equal(model.filterChordKey("c"), "closed");
assert.equal(model.filterChordKey("s"), "snoozed");
assert.equal(model.filterChordKey("a"), "all");
assert.equal(model.filterChordKey("x"), "");
assert.equal(model.emptyInboxMessage("closed"), "No closed conversations.");
assert.equal(model.emptyInboxMessage("snoozed"), "No snoozed conversations.");
assert.equal(model.emptyInboxMessage("all"), "No conversations.");
assert.equal(model.filterInbox([
  { id: "open", state: "open", waitingSince: 0 },
  { id: "wait", state: "open", waitingSince: 9 },
  { id: "done", state: "closed", waitingSince: 0 },
  { id: "later", state: "snoozed", waitingSince: 0 }
], "closed").map(function(row) { return row.id; }).join(","), "done");
assert.equal(model.filterInbox([
  { id: "open", state: "open", waitingSince: 0 },
  { id: "done", state: "closed", waitingSince: 0 },
  { id: "later", state: "snoozed", waitingSince: 0 }
], "snoozed").map(function(row) { return row.id; }).join(","), "later");
assert.equal(model.filterInbox([
  { id: "open", state: "open", waitingSince: 0 },
  { id: "done", state: "closed", waitingSince: 0 },
  { id: "later", state: "snoozed", waitingSince: 0 }
], "all").map(function(row) { return row.id; }).join(","), "open,done,later");
assert.equal(model.filterInbox([
  { id: "open", state: "open", waitingSince: 0 },
  { id: "wait", state: "open", waitingSince: 9 },
  { id: "done", state: "closed", waitingSince: 9 }
], "waiting").map(function(row) { return row.id; }).join(","), "wait");

assert.equal(model.formatWaiting(1000, (1000 + 40) * 1000), "just now");
assert.equal(model.formatWaiting(1000, (1000 + 5 * 60) * 1000), "5m");
assert.equal(model.formatWaiting(1000, (1000 + 2 * 3600) * 1000), "2h");
assert.equal(model.formatWaiting(1000, (1000 + 3 * 86400) * 1000), "3d");
assert.equal(model.formatWaiting(0, Date.now()), "");
assert.equal(model.formatMessageTime(1000, (1000 + 5 * 60) * 1000), "5m");
assert.equal(model.formatMessageTime(0, Date.now()), "");

assert.equal(model.barLabel(0, 0, false), "󰍡 0/0");
assert.equal(model.barLabel(3, 10, false), "󰍡 3/10");
assert.equal(model.barLabel(3, 10, true), "󰍡\n3/10");

assert.equal(model.tooltipText(0, 0, "ready", ""), "0 waiting · 0 open");
assert.equal(model.tooltipText(2, 4, "ready", ""), "2 waiting · 4 open");
assert.equal(model.tooltipText(0, 0, "unconfigured", "x"), "Intercom · sign in");
assert.match(model.tooltipText(0, 0, "error", "token rejected"), /token rejected/);
assert.equal(model.tooltipText(0, 0, "loading", ""), "Checking Intercom…");
assert.equal(model.tooltipText(0, 0, "loading", "Checking Intercom…"), "Checking Intercom…");

assert.match(model.heroMeta("ready", "", 2), /2 conversations waiting/);
assert.equal(model.heroDetail("ready", 2), "WAITING");
assert.equal(model.heroDetail("ready", 0), "CLEAR");
assert.equal(model.heroDetail("unconfigured", 0), "SETUP");
assert.equal(model.statusMessage("ready", "ignored"), "");
assert.equal(model.statusMessage("error", "boom"), "boom");
assert.equal(model.isSafeHttpUrl("https://example.com"), true);
assert.equal(model.isSafeHttpUrl("http://example.com/x"), true);
assert.equal(model.isSafeHttpUrl("javascript:alert(1)"), false);
assert.equal(model.isSafeHttpUrl(""), false);
assert.equal(model.isSafeHttpUrl("example.com"), false);

assert.equal(model.threadCacheTtlMs(), 120000);
assert.equal(model.cachedThreadFresh(null, 200000, 120000), false);
const cached = model.writeCachedThread({}, {
  id: "1295",
  title: "Billing question",
  messages: [{ id: "1", from: "Ada", kind: "customer", createdAt: 100, body: "Help please" }]
}, 100000);
const cachedEntry = model.readCachedThread(cached, "1295");
assert.equal(cachedEntry.conversation.id, "1295");
assert.equal(cachedEntry.conversation.messages.length, 1);
assert.equal(cachedEntry.fetchedAt, 100000);
assert.equal(cachedEntry.complete, true);
assert.equal(model.cachedThreadFresh(cachedEntry, 100000 + 119999, 120000), true);
assert.equal(model.cachedThreadFresh(cachedEntry, 100000 + 120000, 120000), false);
assert.equal(model.prefetchResultStale(null, 100000), false);
assert.equal(model.prefetchResultStale(cachedEntry, 100001), false);
assert.equal(model.prefetchResultStale(cachedEntry, 100000), true);
assert.equal(model.prefetchResultStale(cachedEntry, 99999), true);
const preview = model.writeCachedThread({}, {
  id: "1295",
  title: "Billing question",
  messages: [{ id: "1", from: "Ada", kind: "customer", createdAt: 100, body: "Help please" }]
}, 100000, false);
const previewEntry = model.readCachedThread(preview, "1295");
assert.equal(previewEntry.complete, false);
assert.equal(model.prefetchResultStale(previewEntry, 100000), false);
assert.equal(model.cachedThreadFresh(previewEntry, 100000 + 1000, 120000), false);
assert.equal(model.readCachedThread(cached, "missing"), null);
assert.equal(model.threadPrefetchGapMs(), 400);
assert.equal(model.prefetchThreadIds([
  { id: "1" },
  { id: "2" },
  { id: "3" }
], "2", {}, 100000, 120000, false).join(","), "2,1,3");
assert.equal(model.prefetchThreadIds([
  { id: "1" },
  { id: "2" }
], "2", cached, 100000 + 1000, 120000, false).join(","), "2,1");
assert.equal(model.prefetchThreadIds(["1", "1295"], "1295", cached, 100000 + 1000, 120000, false).join(","), "1");
assert.equal(model.prefetchThreadIds(["1", "1295"], "1295", preview, 100000 + 1000, 120000, false).join(","), "1295,1");
assert.equal(model.prefetchThreadIds(["1", "1295"], "1295", cached, 100000 + 1000, 120000, true).join(","), "1295,1");
const expired = model.expireCachedThreads(cached, [{ id: "1295" }]);
const expiredEntry = model.readCachedThread(expired, "1295");
assert.equal(expiredEntry.complete, false);
assert.equal(expiredEntry.fetchedAt, 0);
assert.equal(expiredEntry.conversation.messages.length, 1);
assert.equal(model.cachedThreadFresh(expiredEntry, 100000, 120000), false);
assert.equal(model.readCachedThread(model.expireCachedThreads(cached, [{ id: "missing" }]), "1295").complete, true);
assert.equal(model.readCachedThread(model.expireCachedThreads({}, [{ id: "1295" }]), "1295"), null);

assert.equal(model.findConversationById([{ id: "1" }, { id: "1295", from: "Ada" }], "1295").from, "Ada");
assert.equal(model.findConversationById([{ id: "1" }], "missing"), null);
assert.equal(model.findConversationById([{ id: "" }], ""), null);
assert.equal(JSON.stringify(model.removeConversation([
  { id: "1" },
  { id: "2" },
  { id: "3" }
], "2")), JSON.stringify([{ id: "1" }, { id: "3" }]));
assert.equal(JSON.stringify(model.removeConversation([{ id: "1" }], "missing")), JSON.stringify([{ id: "1" }]));
assert.equal(model.adjacentConversation([{ id: "1" }, { id: "2" }, { id: "3" }], "2").id, "3");
assert.equal(model.adjacentConversation([{ id: "1" }, { id: "2" }, { id: "3" }], "3").id, "2");
assert.equal(model.adjacentConversation([{ id: "1" }], "1"), null);
assert.equal(model.adjacentConversation([{ id: "1" }, { id: "2" }], "missing"), null);
assert.equal(model.conversationStateOf({ state: "closed" }), "closed");
assert.equal(model.conversationStateOf({ state: "OPEN" }), "open");
assert.equal(JSON.stringify(model.setConversationState([
  { id: "1", state: "closed", from: "Ada" },
  { id: "2", state: "closed" }
], "1", "open")), JSON.stringify([
  { id: "1", state: "open", from: "Ada" },
  { id: "2", state: "closed" }
]));
assert.equal(JSON.stringify(model.setConversationState([{ id: "1", state: "closed" }], "missing", "open")), JSON.stringify([{ id: "1", state: "closed" }]));
assert.equal(model.setConversationState([{ id: "1", state: "closed" }], "1", "snoozed")[0].state, "snoozed");
assert.equal(model.conversationForState({ id: "1", title: "Billing", state: "open", waitingSince: 9, updatedAt: 10 }, "closed", 50000).state, "closed");
assert.equal(model.conversationForState({ id: "1", waitingSince: 9, updatedAt: 10 }, "closed", 50000).waitingSince, 0);
assert.equal(model.conversationForState({ id: "1", updatedAt: 10 }, "closed", 50000).updatedAt, 50);
assert.equal(model.prependConversation([{ id: "2" }, { id: "1", title: "Old" }], { id: "1", title: "New", state: "closed" })[0].title, "New");
assert.equal(model.prependConversation([{ id: "2" }], { id: "1", state: "closed" }).map(function(row) { return row.id; }).join(","), "1,2");
assert.equal(model.prependConversation([], { id: "" }).length, 0);
const moved = model.setPendingInboxMove({}, { id: "1", title: "Billing", state: "open" }, "closed", 100000);
assert.equal(moved["1"].state, "closed");
assert.equal(model.hasPendingInboxMoves(moved, 100000), true);
assert.equal(model.hasPendingInboxMoves(moved, 100000 + model.pendingInboxMoveTtlMs() + 1), false);
assert.equal(model.applyPendingInboxMoves(
  [{ id: "2", state: "closed" }],
  "closed",
  moved,
  100000
).map(function(row) { return row.id; }).join(","), "1,2");
assert.equal(model.applyPendingInboxMoves(
  [{ id: "1", state: "open" }, { id: "3", state: "open" }],
  "open",
  moved,
  100000
).map(function(row) { return row.id; }).join(","), "3");

const previous = model.conversationIndex([
  { id: "1", waitingSince: 100, from: "Ada", snippet: "Hi" },
  { id: "2", waitingSince: 50, from: "Bo", snippet: "Old" }
]);
assert.equal(previous["1"].waitingSince, 100);
assert.equal(model.newMessageConversations(previous, [
  { id: "1", waitingSince: 100, from: "Ada", snippet: "Hi" },
  { id: "2", waitingSince: 50, from: "Bo", snippet: "Old" }
]).length, 0);
assert.equal(model.newMessageConversations(previous, [
  { id: "1", waitingSince: 100, from: "Ada", snippet: "Hi" },
  { id: "2", waitingSince: 50, from: "Bo", snippet: "Richer snippet" }
]).length, 0);
assert.equal(model.newMessageConversations(previous, [
  { id: "1", waitingSince: 100, from: "Ada", snippet: "Hi" },
  { id: "2", waitingSince: 80, from: "Bo", snippet: "Follow-up" }
])[0].id, "2");
assert.equal(model.newMessageConversations(previous, [
  { id: "3", waitingSince: 200, from: "Cy", snippet: "New thread" },
  { id: "1", waitingSince: 100, from: "Ada", snippet: "Hi" }
])[0].id, "3");
assert.equal(model.newMessageConversations({}, [
  { id: "1", waitingSince: 10 },
  { id: "2", waitingSince: 20 }
]).map(function(row) { return row.id; }).join(","), "1,2");
assert.equal(model.notificationsToSend({}, [
  { id: "1", waitingSince: 10 },
  { id: "2", waitingSince: 20 },
  { id: "3", waitingSince: 30 },
  { id: "4", waitingSince: 40 },
  { id: "5", waitingSince: 50 },
  { id: "6", waitingSince: 60 }
], 3).map(function(row) { return row.id; }).join(","), "4,5,6");
assert.equal(model.notificationLimit(), 5);
assert.equal(model.notificationHeadline({ from: "Ada Lovelace", snippet: "Please help" }), "Ada Lovelace");
assert.equal(model.notificationHeadline({ snippet: "Please help" }), "Intercom");
assert.equal(model.notificationHeadline({ from: "-Ada" }), "–Ada");
assert.equal(model.notificationBody({ from: "Ada", snippet: "Please help with billing" }), "Please help with billing");
assert.equal(model.notificationBody({ title: "Billing", snippet: "" }), "Billing");
assert.ok(model.notificationBody({ snippet: "x".repeat(200) }).endsWith("…"));
assert.ok(model.notificationBody({ snippet: "x".repeat(200) }).length <= 120);
assert.equal(model.shellQuote("1295"), "'1295'");
assert.equal(model.shellQuote("a'b"), "'a'\\''b'");
assert.equal(model.notificationExec({ id: "1295" }), "omarchy-shell intercom-notifier conversation '1295'");
assert.equal(model.notificationExec({}), "omarchy-shell intercom-notifier open");
const notifyCmd = model.notificationCommand({
  id: "1295",
  from: "Ada",
  snippet: "Please help"
});
assert.equal(notifyCmd[0], "omarchy-notification-send");
assert.equal(notifyCmd[notifyCmd.indexOf("--app-name") + 1], "Intercom");
assert.equal(notifyCmd[notifyCmd.indexOf("--exec") + 1], "omarchy-shell intercom-notifier conversation '1295'");
assert.equal(notifyCmd[notifyCmd.length - 2], "Ada");
assert.equal(notifyCmd[notifyCmd.length - 1], "Please help");

assert.equal(model.parseFetch(JSON.stringify({
  state: "ready",
  adminId: "42",
  adminName: "Ada",
  adminEmail: "ada@example.com",
  conversations: []
})).adminName, "Ada");
assert.equal(model.adminLabel("Ada", "ada@example.com", ""), "Ada");
assert.equal(model.adminLabel("", "ada@example.com", ""), "ada@example.com");
assert.equal(model.adminInitials("Ada Lovelace", "ada@example.com"), "AL");
assert.equal(model.adminInitials("Ada", ""), "A");
assert.equal(model.adminInitials("", "ada@example.com"), "A");
assert.equal(model.adminInitials("", ""), "");
assert.equal(model.adminEmailLine("Ada", "ada@example.com"), "ada@example.com");
assert.equal(model.adminEmailLine("", "ada@example.com"), "");
assert.equal(model.hasAdminProfile("Ada", ""), true);
assert.equal(model.hasAdminProfile("", "ada@example.com"), true);
assert.equal(model.hasAdminProfile("", ""), false);
assert.equal(model.isSignedIn("ready", "", "", ""), true);
assert.equal(model.isSignedIn("unconfigured", "Ada", "ada@example.com", "42"), false);
assert.equal(model.isSignedIn("error", "Ada", "", "42"), true);
assert.equal(model.isSignedIn("error", "", "", ""), false);
assert.equal(model.markdownToStyled("**bold**"), "<b>bold</b>");
assert.equal(model.markdownToStyled("__bold__"), "<b>bold</b>");
assert.equal(model.markdownToStyled("*italic*"), "<i>italic</i>");
assert.equal(model.markdownToStyled("_italic_"), "<i>italic</i>");
assert.equal(model.markdownToStyled("line1\nline2"), "line1<br>line2");
assert.equal(JSON.stringify(model.messageParagraphs("")), "[]");
assert.equal(JSON.stringify(model.messageParagraphs("Hello")), JSON.stringify(["Hello"]));
assert.equal(JSON.stringify(model.messageParagraphs("Hello<br>World")), JSON.stringify(["Hello<br>World"]));
assert.equal(JSON.stringify(model.messageParagraphs("Hello<br><br>World")), JSON.stringify(["Hello", "World"]));
assert.equal(JSON.stringify(model.messageParagraphs("Hello<br><br><br>World")), JSON.stringify(["Hello", "World"]));
assert.equal(JSON.stringify(model.messageParagraphs("Hello<br> <br>World")), JSON.stringify(["Hello", "World"]));
assert.equal(JSON.stringify(model.messageParagraphs("Hello\n\nWorld")), JSON.stringify(["Hello", "World"]));
assert.equal(JSON.stringify(model.messageParagraphs("<b>Hi</b><br><br>See <a href=\"https://example.com\">this</a>")), JSON.stringify([
  "<b>Hi</b>",
  "See <a href=\"https://example.com\">this</a>"
]));
assert.equal(
  model.markdownToStyled("[docs](https://example.com/path)"),
  '<a href="https://example.com/path">docs</a>'
);
assert.equal(model.markdownToStyled("[x](javascript:alert(1))"), "[x](javascript:alert(1))");
assert.equal(model.markdownToStyled("<b>raw</b>"), "&lt;b&gt;raw&lt;/b&gt;");
assert.equal(model.markdownToStyled("not_mid_word"), "not_mid_word");
assert.equal(model.heroMeta("unconfigured", "", 0), "Sign in with Intercom to connect");
assert.equal(model.OAUTH_REDIRECT_URL, "http://localhost:18741/callback");
assert.equal(model.isSafeConversationId("1295"), true);
assert.equal(model.isSafeConversationId("conv_1"), true);
assert.equal(model.isSafeConversationId(""), false);
assert.equal(model.isSafeConversationId("1295/other"), false);
assert.equal(model.isSafeConversationId("1295 other"), false);
assert.equal(JSON.stringify(model.parseDrafts("")), "{}");
assert.equal(JSON.stringify(model.parseDrafts("not-json")), "{}");
assert.equal(model.draftText(model.parseDrafts(JSON.stringify({
  "1295": "Hello **Ada**",
  "../etc": "nope",
  "  ": "skip",
  "empty": "   "
})), "1295"), "Hello **Ada**");
assert.equal(model.draftIsNote(model.parseDrafts(JSON.stringify({
  "1295": { body: "Private", note: true }
})), "1295"), true);
assert.equal(model.draftIsNote({ "1295": "saved" }, "1295"), false);
assert.equal(model.draftText({ "1295": "saved" }, "missing"), "");
assert.equal(JSON.stringify(model.setDraft({ "1295": "old", "other": "keep" }, "1295", "new")), JSON.stringify({
  "1295": { body: "new", note: false },
  "other": { body: "keep", note: false }
}));
assert.equal(JSON.stringify(model.setDraft({}, "1295", "note me", true)), JSON.stringify({
  "1295": { body: "note me", note: true }
}));
assert.equal(JSON.stringify(model.setDraft({ "1295": "old" }, "1295", "   ")), "{}");
assert.equal(model.draftText(model.setDraft({}, "bad id", "nope"), "bad id"), "");
assert.equal(JSON.stringify(model.deleteLastWord("hello world", 11)), JSON.stringify({ text: "hello ", cursor: 6 }));
assert.equal(JSON.stringify(model.deleteLastWord("hello world ", 12)), JSON.stringify({ text: "hello ", cursor: 6 }));
assert.equal(JSON.stringify(model.deleteLastWord("hello world", 5)), JSON.stringify({ text: " world", cursor: 0 }));
assert.equal(JSON.stringify(model.deleteLastWord("hi", 0)), JSON.stringify({ text: "hi", cursor: 0 }));
assert.equal(JSON.stringify(model.deleteLastWord("", 0)), JSON.stringify({ text: "", cursor: 0 }));
assert.equal(JSON.stringify(model.deleteLineBeforeCursor("hello", 5)), JSON.stringify({ text: "", cursor: 0 }));
assert.equal(JSON.stringify(model.deleteLineBeforeCursor("hello", 2)), JSON.stringify({ text: "llo", cursor: 0 }));
assert.equal(JSON.stringify(model.deleteLineBeforeCursor("aaa\nbbb", 7)), JSON.stringify({ text: "aaa\n", cursor: 4 }));
assert.equal(JSON.stringify(model.deleteLineBeforeCursor("aaa\nbbb", 4)), JSON.stringify({ text: "aaa\nbbb", cursor: 4 }));
assert.equal(JSON.stringify(model.deleteLineBeforeCursor("aaa\nbbb", 3)), JSON.stringify({ text: "\nbbb", cursor: 0 }));
assert.equal(JSON.stringify(model.seenComments([
  { id: "1", kind: "customer", createdAt: 10, body: "Hi" },
  { id: "note", kind: "note", createdAt: 11, body: "Internal" },
  { id: "2", kind: "teammate", createdAt: 12, body: "On it" },
  { id: "", kind: "customer", createdAt: 13, body: "Skip" }
])), JSON.stringify([
  { id: "1", createdAt: 10 },
  { id: "note", createdAt: 11 },
  { id: "2", createdAt: 12 }
]));

assert.equal(JSON.stringify(model.filterInbox([
  { id: "open", waitingSince: 0 },
  { id: "wait", waitingSince: 9 }
], true)), JSON.stringify([{ id: "wait", waitingSince: 9 }]));
assert.equal(JSON.stringify(model.resolveInboxSelection([], false, "", 0)), JSON.stringify({ index: 0, id: "" }));
assert.equal(JSON.stringify(model.resolveInboxSelection([
  { id: "newest" },
  { id: "older" }
], false, "", 0)), JSON.stringify({ index: 0, id: "newest" }));
assert.equal(JSON.stringify(model.resolveInboxSelection([
  { id: "newest" },
  { id: "older" }
], false, "older", 0)), JSON.stringify({ index: 1, id: "older" }));
assert.equal(JSON.stringify(model.resolveInboxSelection([
  { id: "newest" },
  { id: "older" }
], false, "gone", 0)), JSON.stringify({ index: 0, id: "newest" }));
assert.equal(JSON.stringify(model.resolveInboxSelection([
  { id: "open", waitingSince: 0 },
  { id: "wait", waitingSince: 9 }
], true, "", 0)), JSON.stringify({ index: 0, id: "wait" }));

assert.equal(JSON.stringify(model.queuedThreadAfterInFlight("1295", "", false, "1295", false)), JSON.stringify({ id: "", force: false }));
assert.equal(JSON.stringify(model.queuedThreadAfterInFlight("1295", "", false, "1295", true)), JSON.stringify({ id: "1295", force: true }));
assert.equal(JSON.stringify(model.queuedThreadAfterInFlight("1295", "1295", false, "1295", true)), JSON.stringify({ id: "1295", force: true }));
assert.equal(JSON.stringify(model.queuedThreadAfterInFlight("1295", "other", true, "1295", true)), JSON.stringify({ id: "other", force: true }));
assert.equal(JSON.stringify(model.queuedThreadAfterInFlight("1295", "", false, "other", true)), JSON.stringify({ id: "other", force: true }));
assert.equal(JSON.stringify(model.queuedThreadAfterInFlight("1295", "queued", false, "other", false)), JSON.stringify({ id: "other", force: false }));

assert.equal(model.pendingUrgentCount({}), 0);
assert.equal(model.pendingUrgentCount({ a: true, b: true }), 2);
assert.equal(model.pendingUrgentCount({ "../x": true }), 0);

assert.equal(model.parseDiskCache("").ready, false);
assert.equal(model.parseDiskCache("not-json").ready, false);
assert.equal(model.parseDiskCache(JSON.stringify({ version: 1 })).ready, false);
assert.equal(model.parseDiskCache(model.serializeDiskCache(model.emptyDiskCache())).ready, false);
const storedInbox = model.writeInboxCache({}, "closed", [
  { id: "9", title: "Old", from: "Ada", state: "closed" }
], 4, 50);
assert.equal(model.readInboxCache(storedInbox, "closed").count, 4);
assert.equal(model.readInboxCache(storedInbox, "closed").conversations[0].id, "9");
assert.equal(model.inboxCacheConversations(storedInbox)[0].title, "Old");
assert.equal(model.inboxSourceKey("waiting"), "open");
const disk = model.parseDiskCache(model.serializeDiskCache({
  ready: true,
  fetchedAt: 99,
  state: "ready",
  message: "",
  waitingCount: 1,
  openCount: 3,
  closedCount: 4,
  snoozedCount: 0,
  allCount: 7,
  inboxUrl: "https://app.intercom.com/a/inbox/abc/inbox/shared/all",
  workspaceId: "abc",
  adminId: "42",
  adminName: "Ada",
  adminEmail: "ada@example.com",
  conversations: [{
    id: "1295",
    title: "Billing question",
    from: "Ada",
    snippet: "Please help",
    messages: [{ id: "1", from: "Ada", kind: "customer", createdAt: 100, body: "Help please" }]
  }],
  inboxes: storedInbox,
  threads: model.writeCachedThread({}, {
    id: "1295",
    title: "Billing question",
    messages: [{ id: "1", from: "Ada", kind: "customer", createdAt: 100, body: "Help please" }]
  }, 100000)
}));
assert.equal(disk.ready, true);
assert.equal(disk.waitingCount, 1);
assert.equal(disk.openCount, 3);
assert.equal(disk.closedCount, 4);
assert.equal(disk.conversations[0].id, "1295");
assert.equal(disk.conversations[0].messages[0].body, "Help please");
assert.equal(disk.inboxes.closed.conversations[0].id, "9");
assert.equal(model.readCachedThread(disk.threads, "1295").fetchedAt, 100000);
assert.equal(model.readCachedThread(disk.threads, "1295").complete, true);

assert.equal(model.dateFormatMonthFirst("M/d/yyyy"), true);
assert.equal(model.dateFormatMonthFirst("dd/MM/yyyy"), false);
assert.equal(model.dateFormatMonthFirst("d.M.yyyy"), false);
assert.equal(model.localeMonthFirst("en-US"), true);
assert.equal(model.localeMonthFirst("en-GB"), false);

function assertSchedule(text, now, year, month, day, hour, minute, options) {
  const got = model.parseScheduleText(text, now, options);
  const want = new Date(year, month, day, hour, minute, 0, 0).getTime();
  assert.equal(got.ok, true, `${text}: ${got.error}`);
  assert.equal(got.at, want, `${text}: got ${new Date(got.at).toString()}`);
}

function assertScheduleInvalid(text, now, options) {
  const got = model.parseScheduleText(text, now, options);
  assert.equal(got.ok, false, text);
}

const fridayAfternoon = new Date(2026, 7, 21, 14, 30, 0, 0).getTime();
assertSchedule("22:10", fridayAfternoon, 2026, 7, 21, 22, 10);
assertSchedule("tomorrow at 8", fridayAfternoon, 2026, 7, 22, 8, 0);
assertSchedule("Monday", fridayAfternoon, 2026, 7, 24, 9, 0);
assertScheduleInvalid("yesterday", fridayAfternoon);
assertSchedule("22:10", new Date(2026, 7, 21, 23, 0, 0, 0).getTime(), 2026, 7, 22, 22, 10);
assertSchedule("Monday", new Date(2026, 7, 24, 8, 0, 0, 0).getTime(), 2026, 7, 24, 9, 0);
assertSchedule("Monday", new Date(2026, 7, 24, 10, 0, 0, 0).getTime(), 2026, 7, 31, 9, 0);
assertSchedule("tonight", fridayAfternoon, 2026, 7, 21, 21, 0);
assertSchedule("April 7", fridayAfternoon, 2027, 3, 7, 9, 0);
assertSchedule("in 2 hours", fridayAfternoon, 2026, 7, 21, 16, 30);
assertSchedule("this morning", fridayAfternoon, 2026, 7, 21, 15, 30);
assertSchedule("this morning", new Date(2026, 7, 21, 8, 0, 0, 0).getTime(), 2026, 7, 21, 9, 0);
assertSchedule("tomorrow evening", fridayAfternoon, 2026, 7, 22, 18, 0);
assertSchedule("Tuesday afternoon", fridayAfternoon, 2026, 7, 25, 13, 0);
assertSchedule("4/7", fridayAfternoon, 2027, 3, 7, 9, 0, { monthFirst: true });
assertSchedule("4/7", fridayAfternoon, 2027, 6, 4, 9, 0, { monthFirst: false });
assertSchedule("4/7", new Date(2026, 2, 1, 10, 0, 0, 0).getTime(), 2026, 3, 7, 9, 0, { monthFirst: true });
assertSchedule("4/7", new Date(2026, 2, 1, 10, 0, 0, 0).getTime(), 2026, 6, 4, 9, 0, { monthFirst: false });
assertScheduleInvalid("today at 8", fridayAfternoon);
assertSchedule("8am", fridayAfternoon, 2026, 7, 22, 8, 0);
assertSchedule("in 30 minutes", fridayAfternoon, 2026, 7, 21, 15, 0);
assert.notEqual(model.formatScheduleTime(fridayAfternoon), "");
assert.match(model.formatScheduleTime(new Date(2026, 7, 21, 22, 10, 0, 0).getTime()), /10/u);

assert.equal(JSON.stringify(model.parseScheduled("")), "[]");
assert.equal(JSON.stringify(model.parseScheduled("not-json")), "[]");
const queued = model.addScheduled([], "1295", "Hello later", false, fridayAfternoon + 3600000, fridayAfternoon);
assert.equal(queued.length, 1);
assert.equal(queued[0].conversationId, "1295");
assert.equal(queued[0].body, "Hello later");
assert.equal(queued[0].note, false);
assert.equal(queued[0].sendAt, fridayAfternoon + 3600000);
assert.equal(model.hasScheduled(queued, "1295"), true);
assert.equal(model.hasScheduled(queued, "other"), false);
assert.equal(model.dueScheduled(queued, fridayAfternoon).length, 0);
assert.equal(model.dueScheduled(queued, fridayAfternoon + 3600000).length, 1);
assert.equal(model.removeScheduled(queued, queued[0].id).length, 0);
assert.equal(JSON.stringify(model.addScheduled([], "bad id", "nope", false, fridayAfternoon + 1, fridayAfternoon)), "[]");
assert.equal(model.parsePickerDate(2026, 7, 22, 9, 0, fridayAfternoon).ok, true);
assert.equal(model.parsePickerDate(2026, 7, 21, 9, 0, fridayAfternoon).ok, false);
assert.equal(model.monthCells(2026, 7, 1)[0].length, 7);
assert.equal(JSON.stringify(model.stepMonth(2026, 7, 1)), JSON.stringify({ year: 2026, month: 8 }));
assert.equal(JSON.stringify(model.weekdayOrder(1)), JSON.stringify([1, 2, 3, 4, 5, 6, 0]));

const focusItems = model.threadFocusItems(
  [{ id: "1" }, { id: "2" }],
  true,
  [{ id: "s1" }]
);
assert.equal(focusItems.length, 6);
assert.equal(focusItems[0].kind, "message");
assert.equal(focusItems[0].key, "message:1");
assert.equal(focusItems[1].key, "message:2");
assert.equal(focusItems[2].kind, "draft");
assert.equal(focusItems[3].kind, "draft-action");
assert.equal(focusItems[4].kind, "scheduled");
assert.equal(focusItems[4].key, "scheduled:s1");
assert.equal(focusItems[5].kind, "scheduled-action");
assert.equal(model.lastThreadMessageIndex(focusItems), 4);
assert.equal(JSON.stringify(model.threadFocusItems([], false, [])), "[]");
assert.equal(model.resolveThreadFocus(focusItems, "message:2", -1, false).index, 1);
assert.equal(model.resolveThreadFocus(focusItems, "gone", -1, true).index, 4);
assert.equal(model.resolveThreadFocus(focusItems, "", -1, false).index, -1);
assert.equal(model.resolveThreadFocus(focusItems, "gone", 5, false).index, 5);
assert.equal(model.moveThreadFocus(focusItems, "", -1, 1).index, 0);
assert.equal(model.moveThreadFocus(focusItems, "", -1, 1).key, "message:1");
assert.equal(model.moveThreadFocus(focusItems, "", -1, -1).index, 5);
assert.equal(model.moveThreadFocus(focusItems, "message:2", 1, 1).key, "draft");
assert.equal(model.moveThreadFocus(focusItems, "draft", 2, 1).key, "draft-action");
assert.equal(model.moveThreadFocus(focusItems, "scheduled:s1", 4, 1).key, "scheduled-action:s1");
assert.equal(model.moveThreadFocus(focusItems, "scheduled-action:s1", 5, 1).index, 5);
assert.equal(model.isThreadMessageKind("draft"), true);
assert.equal(model.isThreadMessageKind("draft-action"), false);

console.log("model tests passed");
