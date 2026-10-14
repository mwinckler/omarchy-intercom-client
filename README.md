# Intercom notifier

An Omarchy bar widget that lets you manage messages in your Intercom helpdesk
without needing to interact with Intercom's own web interface.

The plugin includes the following features:

- Status bar icon indicating how many conversations are waiting for a reply (any conversation where the last reply was not a team member), how many total conversations are open, and whether there new messages you haven't seen yet
- A pane showing a list of conversations matching the current filter (Open, Waiting (for reply), Closed, Snoozed, or All) and the ability to navigate through conversations and view all messages in them
- An inline editor to reply to a conversation (or add a private note) using Markdown
- The ability to schedule replies for a future date instead of sending right away (handy for answering customer support in the middle of the night while not wanting to give customers the impression that you're available at all hours)


## Install

```bash
omarchy plugin add <git-url> --enable
```

Or copy this folder to `~/.config/omarchy/plugins/intercom-notifier` and enable
it:

```bash
omarchy plugin enable intercom-notifier --section right
```

## Sign in

One teammate creates a private Intercom app in the
[Developer Hub](https://app.intercom.com/a/developers) and enables **Use OAuth**.
Everyone else signs in with that same app. Do not share a workspace Access Token;
that credential can post as any admin.

On the app's Authentication page:

1. Tick **Use OAuth**.
2. Add redirect URL `http://localhost:18741/callback`.
3. Grant **Read conversations**, **Write conversations**, and **Read admins**.
   Read admins is required for the profile indicator and to reply as yourself.
4. Copy the Client ID and Client secret.

Do not put those values in `shell.json`. Paste them on the plugin's settings page
(gear icon or `s`) and click **Sign in with Intercom**. The browser asks you to
authorize; the plugin stores your personal OAuth token at
`~/.config/omarchy/intercom-notifier/token` (`0700` directory, `0600` file) and
the app credentials at `~/.config/omarchy/intercom-notifier/oauth.json`. Replies
always use `GET /me` for that token, so they appear as you. While signed in, the
panel shows your teammate name and email in the top right, with a **Sign out**
link that removes the saved token and leaves the app credentials in place so you
can sign in again. If the profile says **No teammate profile**, the token is
missing **Read admins** — grant that on the app, then **Sign in again**.

Intercom OAuth tokens do not expire on a timer and do not include a refresh
token. If you revoke the app, the plugin asks you to sign in again.

Conversation links need your **workspace ID**. The plugin infers it from waiting
conversations when Intercom includes a company on the thread, and from `GET /me`.
It caches that in `~/.config/omarchy/intercom-notifier/config.json`. If links
still fail, paste any inbox URL (the segment after `/a/inbox/`).

A `token` file next to the plugin (for example
`~/.config/omarchy/plugins/intercom-notifier/token`) is also accepted.

Resolution order:

1. `INTERCOM_ACCESS_TOKEN` environment variable
2. Widget setting **Access token file**
3. `~/.config/omarchy/intercom-notifier/token`
4. `token` in the plugin directory

US, EU, and AU API hosts are tried automatically. The region that succeeds is cached in `~/.config/omarchy/intercom-notifier/config.json`.

## Controls

- Left click: open or close the panel
- Right click: refresh now
- Middle click: open the Intercom inbox home
- Expanded reader: `j`/`k` move the conversation list (or scroll the thread when that
  pane is focused), `h`/`l` switch panes, `f` then `o`/`w`/`c`/`s`/`a` to filter open,
  waiting, closed, snoozed, or all conversations, `e` to enlarge the panel, `s` for
  settings, Enter to reply, `o` to open in the browser, `c` to close or reopen the
  selected conversation, `/` to search, `r` refresh, Esc close
- Large reader: the same expanded controls; `e` returns to the smaller expanded size
- Search (`/`): types against cached conversations first (inbox, thread cache, and the
  local archive). **Ctrl+I** (or `i` after leaving the search box) toggles **Intercom**
  API search vs local cache. Down or Tab leaves the search box so you can move through
  results with `j`/`k` or arrows; Up on the first result (or `/`) returns to the search
  box. Enter opens the selected result; Esc closes search.
- Composer: Enter inserts a newline, Ctrl+Enter sends Markdown (`**bold**`,
  `*italic*`, `[text](url)`). The rendered preview sits above the input as the
  next teammate message. Esc saves a local draft for that conversation; **Discard**
  (or Ctrl+Shift+D) throws it away. Ctrl+N toggles sending as an internal **Note** instead of
  a public reply. Ctrl+W deletes the previous word; Ctrl+U deletes
  from the start of the line to the cursor. Enter on a conversation with a **DRAFT** badge reopens it for
  editing. Replies are sent as the signed-in teammate.
  Drafts are stored at `~/.config/omarchy/intercom-notifier/drafts.json`.
- Settings: paste the shared app Client ID and secret, then Sign in with Intercom.
  Optional workspace ID for conversation links. Gear icon or `s` opens it; Esc or Back
  returns to the inbox. First-time setup and signed-out errors open this page
  automatically. When signed in, the top-right profile shows who you are and a
  Sign out link. **Sync all conversations** downloads every thread, including
  closed ones, into `~/.config/omarchy/intercom-notifier/archive/` for later
  search. Closed threads are stored once and are not watched for new replies.
- The panel reopens in whichever size you last used (`e` cycles expanded and large),
  on the last conversation you had selected. It reopens that thread even if it is not
  in the current inbox filter. The inbox also remembers the last filter: open, waiting
  for a reply, closed, snoozed, or all.
- A desktop notification appears when a customer message puts a thread into waiting
  (or sends a follow-up on one that is already waiting). The toast shows the sender
  and a preview; clicking it opens this widget expanded on that conversation.
- The bar icon flashes while any fetched messages remain unread locally and stops
  when none remain. Unread message cards have a dot in their upper-left corner.
  Focusing a message with the keyboard or clicking its card marks only that message
  read; merely opening its conversation does not. Read
  status survives restarts in `~/.config/omarchy/intercom-notifier/cache.json` and
  is independent of Intercom's read status; background fetching or closing a
  conversation does not mark it read. Your own replies and notes are excluded.
- Conversation rows also show an unread dot. Unread conversations missing from
  the latest inbox page remain at the top of their matching filter, so older
  unread messages cannot leave the tray flashing without a way to reach them.
- Inbox filters fetch every API page: all open conversations appear in Open,
  regardless of age or count. The API's 150-row page size is not a display limit.

## Keybinding

Omarchy does not ship a shortcut for this plugin. Add one in
`~/.config/hypr/bindings.lua`. **SUPER+SHIFT+I** is free in Omarchy's defaults
(the nearby **SUPER+CTRL+I** toggles idle lock). Confirm with
`omarchy menu keybindings --print` before binding.

```lua
o.bind("SUPER + SHIFT + I", "Intercom", "omarchy-shell intercom-notifier toggle")
```

If that key is already bound, unbind it first:

```lua
hl.unbind("SUPER + SHIFT + I")
o.bind("SUPER + SHIFT + I", "Intercom", "omarchy-shell intercom-notifier toggle")
```

Hyprland reloads the file on save. The shortcut toggles the panel; Esc also
closes it.

## Remove

```bash
omarchy plugin remove intercom-notifier
```

You can also sign out from the panel profile, or delete
`~/.config/omarchy/intercom-notifier/token` and `~/.config/omarchy/intercom-notifier/oauth.json`.

## Development

```bash
omarchy plugin validate .
./tests/run.sh
```
