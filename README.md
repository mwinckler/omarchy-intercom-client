# Intercom notifier

> [!IMPORTANT]
> NOTE FROM A HUMAN: The following is a lightly-edited clanker-generated README.
> On top of that, this whole project is vibe-coded. Treat it accordingly.

An [Omarchy](https://omarchy.org/) shell bar widget for reading and answering
Intercom conversations without keeping the Intercom web app open.

- Bar counts in **waiting/open** format, with flashing for locally unread messages
- A two-pane reader with Open, Waiting, Closed, Snoozed, and All filters
- Public replies and private notes as the signed-in teammate, with Markdown previews
- Local drafts, scheduled sends, file uploads, attachment downloads, and image previews
- Local cache/archive search, optional Intercom API search, and desktop notifications
- Close and reopen conversations, mark senders as spam, or open threads in your browser

**Waiting** means an open, non-snoozed conversation with a positive Intercom
`waiting_since` value. It is not calculated by checking the last message's author.
The counts cover conversations accessible to your token, not just those assigned
to you.

## Requirements

- Omarchy with its Quickshell-based shell and `omarchy plugin` commands. This is
  a shell plugin, not a standalone app or Waybar module.
- Python 3. The API helper uses only the Python standard library.
- For attachment pickers: the system Python's `python-gobject`,
  `xdg-desktop-portal`, and a FileChooser backend (normally GTK on Omarchy).
- An Intercom workspace and an OAuth app with the permissions below.

## Install

```bash
omarchy plugin add https://github.com/mwinckler/omarchy-intercom-client.git --enable
```

Or copy this folder to `~/.config/omarchy/plugins/omarchy-intercom-client` and enable
it:

```bash
omarchy plugin enable omarchy-intercom-client --section right
```

The plugin ID is `omarchy-intercom-client`, regardless of this repository's name.
For a git-managed installation, update with:

```bash
omarchy plugin update omarchy-intercom-client
```

## Sign in

In Intercom, one teammate creates a private Intercom app in the
Developer Hub (Settings -> Integrations -> Developer Hub)
and enables **Use OAuth**.
Everyone else signs in with that same app. Do not share a workspace Access Token;
that credential can post as any admin.

On the app's Authentication page:

1. Tick **Use OAuth**.
2. Add redirect URL `http://localhost:18741/callback`.
3. Grant **Read conversations**, **Write conversations**, and **Read admins**.
   Read admins is required for the profile indicator and to reply as yourself.
   To use **Mark as spam**, also grant **Write users and companies** (contact write access).
4. Copy the Client ID and Client secret.

Do not put those values in `shell.json`. Open the widget, paste them on its
settings page (gear icon or `s`), and click **Sign in with Intercom**. The browser
asks you to authorize; by default, the plugin stores your personal OAuth token at
`~/.config/omarchy/omarchy-intercom-client/token` (`0700` directory, `0600` file) and
the app credentials at `~/.config/omarchy/omarchy-intercom-client/oauth.json` (`0600`).
Replies always use `GET /me` for that token, so they appear as you. While signed in, the
panel shows your teammate name and email in the top right, with a **Sign out**
link that removes the saved token and leaves the app credentials in place so you
can sign in again. If the profile says **No teammate profile**, check that the
app has **Read admins**, then **Sign in again**.

Leave Client ID and secret blank on subsequent sign-ins to reuse the saved app
credentials. If you revoke the app, the plugin asks you to sign in again. Browser
sign-in needs local port `18741` to be available and times out after 150 seconds.

Conversation links need your **workspace ID**. The plugin infers it from waiting
conversations when Intercom includes a company on the thread, and from `GET /me`.
It caches that in `~/.config/omarchy/omarchy-intercom-client/config.json`. If links
still fail, paste your workspace ID or a full inbox URL into settings and click
**Save token or workspace**. The workspace ID is the segment after `/a/inbox/`.

### Advanced token setup

If browser sign-in cannot complete, settings also accepts an existing OAuth
access token. **Access token file** changes where tokens are read and saved.

A `token` file next to the plugin (for example
`~/.config/omarchy/plugins/omarchy-intercom-client/token`) is also accepted.

Resolution order:

1. `INTERCOM_ACCESS_TOKEN` environment variable
2. Widget setting **Access token file**
3. `~/.config/omarchy/omarchy-intercom-client/token`
4. `token` in the plugin directory

US, EU, and AU API hosts are tried automatically. The region that succeeds is
cached in `~/.config/omarchy/omarchy-intercom-client/config.json`.

### Widget settings

These Omarchy widget settings are separate from the in-panel sign-in page:

| Setting | Default | Meaning |
| --- | --- | --- |
| `tokenFile` | Empty | Optional access-token path; falls back to the locations above |
| `refreshIntervalSec` | `60` | Background polling interval in seconds, clamped to `15`–`3600` |

## Controls

| Action | Control |
| --- | --- |
| Open/close the panel | Left click the bar widget |
| Refresh now | Right click the widget, or `r` in the reader |
| Open the Intercom inbox home | Middle click the widget |
| Move through conversations | `j` / `k` or Down / Up in the list pane |
| Switch panes | `h` / `l` or Left / Right |
| Move through messages, drafts, and scheduled sends | `j` / `k` in the thread pane |
| Filter conversations | `f`, then `o` (open), `w` (waiting), `c` (closed), `s` (snoozed), or `a` (all) |
| Toggle expanded/large size | `e` |
| Open settings | Gear icon or `s` |
| Reply or resume a draft | Enter on a conversation |
| Activate the selected thread item | Enter (edit a draft/scheduled send, activate its action, or start a reply) |
| Open the selected conversation in a browser | `o` |
| Close the selected conversation, or reopen it if closed | `c` |
| Search | `/` |
| Back/close | Esc (backs out of the current view or closes the panel; saves a draft when leaving the composer) |

The panel remembers its size, filter, and last selected conversation, even if
that thread is outside the current filter. Toggling an already open panel after
switching workspace or monitor restores its keyboard focus instead of closing it.
Settings opens automatically when setup is missing, the main refresh fails, or the
workspace ID cannot be inferred.

Open, Waiting, and Snoozed fetch every API page. Closed and All show the latest
150 conversations first; **Load more** fetches the next page without hiding the
current list. Tab counts still show the full API totals. Snoozed is a view filter;
the plugin can close/reopen conversations but
does not offer a snooze action.

**Mark as spam** asks for confirmation, then blocks the conversation's sender
using Intercom's contact-blocking API. This prevents new messages and archives
their existing conversations in Intercom; it is not just a close or a local tag.
Known conversations from that sender are removed from the reader/cache, and their
local drafts and scheduled sends are discarded. An explicitly synced local archive
is retained (it is not a live mirror of Intercom).

### Replies and drafts

The composer shows a rendered preview above the input. Its Markdown subset
supports bold, italic, HTTP(S) links, inline code, fenced code blocks, and line
breaks; it is not a full Markdown renderer.

| Action | Control |
| --- | --- |
| Insert a newline | Enter |
| Send immediately | **Send now** or Ctrl+Enter |
| Schedule a send | **Send later...** or Ctrl+S |
| Toggle public reply/private note | **REPLY** / **NOTE** or Ctrl+N |
| Attach local files | **Attach…** or Ctrl+O |
| Save a draft and leave the composer | Esc |
| Discard the draft | **Discard** or Ctrl+Shift+D |
| Delete the previous word | Ctrl+W |
| Delete from the start of the line to the cursor | Ctrl+U |

Closing the panel or switching conversations also saves the current draft.
Enter on a conversation with a **DRAFT** badge resumes it, including its note
mode and selected attachments. Replies and notes use the teammate returned by
`GET /me` for the active token.

Before sending, the helper reloads the conversation. If comments have arrived
since the loaded thread snapshot, it refuses the send with **New comments
arrived; reply was not sent.** Review the updated thread before retrying; your
composer contents are retained.

### Scheduled sends

Write a reply or note, then choose **Send later...** or Ctrl+S. Type a time such
as `tomorrow at 9am`, `in 2 hours`, or `2027-01-15 09:00`, or switch to the
calendar/time picker. Times use your machine's local timezone; ambiguous numeric
dates follow its locale. Review the resolved date/time and confirm the send.

Queued messages appear as **LATER** cards in the thread. Select a card and press
Enter to edit it: this removes the old schedule and returns the message to the
composer. Send or schedule it again; Esc saves it as a draft, not a scheduled
send. **Cancel scheduled** asks for confirmation before removing a queued send.

**Scheduling is local, not hosted by Intercom.** Due sends are checked when the
plugin loads its queue and on each refresh (every 60 seconds by default), so
delivery is not exact to the second. The computer must be awake, with the plugin
running, a valid token, and a working connection. The panel can be closed.
Overdue messages are attempted when the plugin runs again; failed sends remain
queued for a later attempt. The queue is stored in `scheduled.json`.

### Search and archive

`/` opens local search across fetched inboxes, cached threads, and the local
archive. Search includes message text, names/email addresses, and image/file
names. Ctrl+I in the search box (or `i` outside it) toggles **Intercom** API search.
Remote search queries the source author's name/email, subject, and source body;
it is not a full-text search of every reply. Both modes show at most 50 results.

Down or Tab leaves the search box so you can navigate results with `j` / `k` or
arrows. Up on the first result, or `/` outside the input, returns to the search
box. Enter opens the selected result; Esc closes search.

In settings, **Sync all conversations** builds a local archive of conversation
text and metadata, including closed threads, for later search. It does not
download attachment/image files. Already archived closed threads are normally
skipped on later syncs; old content formats are upgraded once. Open and snoozed
threads are fetched again when you sync. The archive is not a live mirror.

### Unread indicators and notifications

The bar flashes while fetched messages in **Open** conversations remain unread
locally. Conversation rows and unread message cards show a dot. Highlighting a
conversation in the focused panel marks its messages read; you do not need to
focus the thread pane. Messages arriving while it remains highlighted are also
marked read. Read state survives restarts and is independent of Intercom's read
status. Background fetching does not mark open conversations read. Closed and
snoozed conversations are treated as read, and your own replies/notes are excluded.
Cached unread conversations missing from the latest inbox response remain
reachable at the top of their matching filter.

Desktop notifications show the sender and a preview; clicking one opens that
conversation in the widget. They are based on newly waiting conversations or an
increase in Intercom's `waiting_since` timestamp, with at most five notifications
per refresh. A follow-up that does not advance that timestamp may become unread
without producing a toast. A first load without a previous snapshot seeds the
notification baseline rather than notifying for the existing backlog.

### Attachments

Messages show attached files with their names, types, and sizes when available.
Click **Download** on a file or image and choose where to save it. Downloads do
not send your Intercom API token and never open or execute the saved file.
The download limit is 100 MiB. If an attachment URL has expired, refresh the
conversation (`r`) and try again.

In the composer, click **Attach…** or press **Ctrl+O** to select files. Use
**Remove** to detach a file before sending. Replies and private notes can contain
up to 10 files, totaling at most 20 MiB; text is optional. Files are uploaded
directly to Intercom when you send, not when you select them. Failed sends keep
the selected files so you can retry.

Drafts and scheduled replies retain the selected local file paths. Keep those
files in place and unchanged until sending; they are read at send time, not
copied into the draft or uploaded ahead of time. Missing, unreadable, or oversized
files prevent the entire message from being sent.

Attachment pickers use your system's default file chooser through XDG Desktop
Portal (GTK on a standard Omarchy install). A separate helper talks to the portal,
so native chooser code never loads inside Quickshell. The panel releases input
while the picker is open and restores focus when it closes. Canceling or failing
to open a picker keeps the draft and selected attachments intact.

Closing the panel also cancels its picker; it does not leave a dialog running
in the background. See [Requirements](#requirements) for portal dependencies.
Download status and picker errors are shown only in the originating conversation.
Use **Dismiss** to clear them; retrying, switching conversations, or closing the
panel also clears the previous status. Save-picker errors do not affect drafts.

Attachment names are included in local search. Cached conversations gain file
attachments when refreshed; **Sync all conversations** upgrades older archive
records without downloading the files themselves.

### Images

The right-hand reader displays inline images and image attachments, including
image-only messages. Previews fit within the message card without cropping;
click a loaded preview to follow its link, or **Open original** to view the
full-size image in your browser. Image filenames and alternative text are
included in local search.

HTTPS images on Intercom's image-hosting domains load automatically near the
visible portion of the selected thread. Other hosts (and known 1×1 images)
require a click to load, so opening an email does not automatically fetch its
external tracking images. No API token is sent with image requests. Local-file,
data, and unresolved email `cid:` sources are not loaded. Previews are static;
animated playback is not supported. Images can be uploaded using **Attach…**,
just like other files.

Image URLs can expire. If a preview fails, refresh the conversation (`r`) to
obtain current URLs or open the original. Metadata is stored with the existing
conversation cache; offline image availability is not guaranteed. Existing
text-only caches remain readable and gain images when refreshed. The next
**Sync all conversations** also upgrades old closed archive records once,
without downloading the image files themselves.

## Keybinding

To add a shortcut for this plugin (e.g. **SUPER+SHIFT+I**), add this to
`~/.config/hypr/bindings.lua` (you may want to check for conflicts with
`omarchy menu keybindings --print` before binding):

```lua
o.bind("SUPER + SHIFT + I", "Intercom", "omarchy-shell omarchy-intercom-client toggle")
```

If that key is already bound, unbind it first:

```lua
hl.unbind("SUPER + SHIFT + I")
o.bind("SUPER + SHIFT + I", "Intercom", "omarchy-shell omarchy-intercom-client toggle")
```

Hyprland reloads the file on save. Validate with `hyprctl reload` and
`hyprctl configerrors`. The shortcut toggles the panel, or restores focus if it
is already open after a workspace/monitor switch.

## Local data and sign-out

Data is stored in `~/.config/omarchy/omarchy-intercom-client/`, or
`$XDG_CONFIG_HOME/omarchy/omarchy-intercom-client/` when that variable is set:

| Path | Contents |
| --- | --- |
| `token` | OAuth access token (unless a custom token file is configured) |
| `oauth.json` | Shared app Client ID and secret |
| `config.json` | API region, workspace, teammate profile, panel size, filter, and last viewed conversation |
| `cache.json` | Inbox/thread cache and local read state |
| `drafts.json` | Draft text, note mode, and local attachment paths |
| `scheduled.json` | Scheduled messages, send times, and local attachment paths |
| `archive/` | Synced thread records, search index, and sync status |

These files contain credentials and customer data and are not encrypted by the
plugin. Do not commit or share them.

**Sign out** removes saved token files (including configured and plugin-local
fallbacks) and clears the active inbox cache/profile. It leaves app credentials,
preferences, drafts, scheduled sends, and the archive in place. If
`INTERCOM_ACCESS_TOKEN` is set in the shell's environment, unset it there to
finish signing out. Signing out locally does not revoke the app in Intercom.
Cancel scheduled sends before switching accounts; the queue is not scoped to a
particular teammate or workspace.

## Remove

Sign out first if you also want to remove saved tokens, then remove the plugin:

```bash
omarchy plugin remove omarchy-intercom-client
```

Removing the plugin does not delete its separate data directory. After removal,
delete that directory yourself if you want to erase credentials, customer data,
drafts, and the scheduled queue. Custom token files and attachments saved to
other locations must be removed separately. Revoke the app in Intercom if you
also want to invalidate its authorization.

## Development

`Panel.qml` implements the widget/reader, `Service.qml` handles processes and
local state, and `Model.js` contains formatting and state helpers.
`intercom-fetch` handles the API, OAuth, archive, and attachment transfers;
`intercom-file-picker` runs the portal chooser outside Quickshell.

The test suite needs Node.js, Python 3, Omarchy's shell imports and plugin CLI,
Quickshell, and Qt 6's `qmllint` and `qtpaths`. From the repository root:

```bash
omarchy plugin validate .
./tests/run.sh
```

`tests/run.sh` runs the JavaScript model tests, Python API and file-picker tests,
manifest validation, QML lint and lint regression tests, and QML/image smoke
tests. Tests use isolated data, fake API/picker helpers, and a loopback image
server; no Intercom credentials are needed. QML lint fails on warnings.

Run `bash tests/lint.sh` for lint alone; `QMLLINT` can select a Qt 6 executable
when Qt 5 is also installed. The lint setup resolves Omarchy's `qs.*` imports
and supplies Quickshell's missing process-exit enum metadata in a temporary
overlay, without modifying installed files or disabling checks.

With the plugin enabled, these IPC commands are available:

```bash
omarchy-shell omarchy-intercom-client toggle
omarchy-shell omarchy-intercom-client refresh
omarchy-shell omarchy-intercom-client conversation CONVERSATION_ID
omarchy-shell omarchy-intercom-client status
omarchy-shell omarchy-intercom-client images
```

`status` reports counts and unread diagnostics. For a running reader, `images`
reports image block counts, preview geometry, loading status, and viewport
eligibility without including message text or signed image URLs. If a plugin
reload retains old QML code, `omarchy restart shell` starts a fresh QML engine.

## License

[MIT](LICENSE).
