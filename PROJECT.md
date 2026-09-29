# chadmux project guide

## Purpose and current scope

Build an iOS SSH terminal. The app saves a list of hosts (see [Hosts](#hosts)), generates an
Ed25519 device key in Keychain, exports only its public key, and requires explicit
first-use host fingerprint verification. Changed host keys refuse reconnects.
The retained SwiftTerm view renders a real Citadel SSH PTY with keyboard input
and resize propagation. Dictation forwarding uses a bounded direct-tcpip channel
to the Mac's loopback API; no public API or local listener is opened.

The collapsible left sidebar lists existing tmux sessions from the same Mac/user.
Its **+** creates a Claude session and **−** ends one, through the Mac's own
`claude-tmux` script (see [Creating and ending sessions](#creating-and-ending-sessions)).
Each of up to eight open tabs owns its terminal connection and persisted draft
and attachments; closing a tab detaches only that client. Multiline message composition and an always-visible terminal control row are
implemented. Camera/library photos with private SFTP upload are implemented. Tap-to-record dictation is implemented. Protected relaunch recovery is implemented. Connection
setup and tests use no committed hosts or credentials.

## Architecture

- `Chadmux/ChadmuxApp.swift`: app entry point.
- `Chadmux/ContentView.swift`: host lifecycle, host verification, sidebar and live terminal.
- `Chadmux/HostProfiles.swift`: saved host profiles, migration from the single Mac connection, and the per-host workspaces.
- `Chadmux/HostSettings.swift`: the host list and host editor.
- `Chadmux/TmuxSessions.swift`: numeric session discovery, instance validation and tab ownership.
- `Chadmux/ClaudeTmux.swift`: login-shell `claude-tmux create`/`close` commands and result parsing.
- `Chadmux/MessageComposer.swift`: literal paste framing, explicit Send, controls and uncertain-delivery handling.
- `Chadmux/DraftRecovery.swift`: atomic protected draft snapshots and uncertain-send checkpoints.
- `Chadmux/VoiceDictation.swift`: microphone lifecycle, origin-bound transcription and editable insertion.
- `Chadmux/PhotoPicker.swift`: camera/library controls and attachment previews/removal.
- `Chadmux/PhotoMedia.swift`: private image conversion/storage and bounded SFTP upload.
- `Chadmux/NativeTerminalView.swift`: finger scrolling, momentum and native selection of visible terminal text.
- `Chadmux/MacTransport.swift`: connection lifecycle, PTY input/output and resizing.
- `Chadmux/ConnectionStore.swift`: scoped Keychain secrets and strict host verification.
- `Chadmux/LoopbackAPI.swift`: bounded HTTP dictation request over a direct SSH channel.
- `ChadmuxUITests/`: simulator launch, navigation and relaunch checks.
- `ChadmuxTests/`: key, terminal and opt-in real SSH integration checks.
- `docs/ssh-terminal-foundation.md`: transport choices and fixture commands.
- `Chadmux/TerminalScreen.swift`: what the transport needs from a terminal view; the iOS view and `MacNativeTerminalView.swift` implement it.
- `Chadmux/ComposerView.swift`: the iOS composer view (the composer model stays shared).
- `ChadmuxMac/`: the native macOS app (in progress; see [macOS app](#macos-app)).
- `Chadmux.xcodeproj`: checked-in Xcode project with the shared Chadmux (iOS) and ChadmuxMac schemes.

Technical commands live here; AGENTS.md and CLAUDE.md are entry points into this
guide. Step-by-step procedures (running each app, preparing hosts, the test
suites, validating a change, troubleshooting) are the
[runbooks](docs/runbooks/README.md); keep them current in the same PR as a
behaviour change. No factory installation is needed for a standalone clone.

## Prerequisites and setup

Use macOS with Xcode 16.4 or newer and an installed iOS simulator runtime. The
app deployment target is iOS 17.0. Xcode resolves the pinned SwiftPM dependencies on the first build.
No project-generation step is required. Open `Chadmux.xcodeproj` in Xcode,
select the Chadmux scheme and an available iOS simulator, then Run.

For agent-driven signed builds, paired wireless iPhone installation, Simulator
and XCUITest commands, read [the iOS delivery runbook](docs/ios-development.md).

## Run locally in Xcode

1. Open `Chadmux.xcodeproj` in Xcode.
2. Select the **Chadmux** scheme and an installed iPhone simulator in the toolbar.
3. Press **Command-R** to build, install and launch the app. No paid developer
   membership is needed for simulator testing.
4. Open **Connection settings** (the first time it opens straight into adding a
   host, labelled Mac), enter the Mac's Tailscale address and username,
   then copy this phone's public key into the Mac's `~/.ssh/authorized_keys`.
   Keep that file private and enable Remote Login on the Mac. Never export the
   private phone key. Save, tap Connect, and independently compare the displayed
   host fingerprint before trusting it.
5. Start tmux on the Mac, then open the top-left sidebar and select a session.
   Tap outside the sidebar to close it; that first tap only dismisses the sidebar
   and does not activate the terminal, composer or other controls underneath.
   The sidebar icon also toggles it, and controls inside the sidebar stay usable.
   Tap the terminal for its keyboard. Closing a tab detaches the phone client;
   the remote session continues. Refresh after sessions change on the Mac. A
   missing/replaced session retains its draft until you explicitly close it.
   Write in the message box and tap Send to paste and submit. Swipe down on the
   message box to dismiss its keyboard without changing the draft; active text
   selections keep the keyboard open for adjusting handles. The remote app
   must advertise bracketed paste; otherwise the draft remains and Send explains
   how to recover. Enter in the terminal control row sends only that key.
   Use Camera or Choose photos to add images; preview/remove thumbnails before
   Send. Tap the microphone to record and tap it again (or Stop) to transcribe.
   Review/edit the result before explicitly tapping Send.

For a physical iPhone, connect and trust the Mac, enable Developer Mode when
prompted, add your Apple account in Xcode settings, and select your team under
**Chadmux target > Signing & Capabilities** with automatic signing. Select your
phone as the run destination and press **Command-R**. A free Personal Team can
be used for initial testing, subject to Apple's provisioning limits. Xcode must
support the phone's installed iOS version. Keep signing changes local and do not
commit credentials. See [Apple's device setup guide](https://developer.apple.com/documentation/xcode/running-your-app-in-simulator-or-on-a-device).

Follow [the iPhone pilot guide](docs/iphone-pilot.md) for key/token setup and the
scenario-level acceptance record.

The agreed sequence is local builds and a working iPhone pilot first, then a
separate TestFlight setup milestone. SwiftUI previews are available for fast UI
iteration when views have preview declarations; the current skeleton does not
include one. Full app testing uses Simulator or the actual phone.

## Build and test

Run from the repository root:

```sh
xcodebuild -project Chadmux.xcodeproj -scheme Chadmux \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

List installed simulators with `xcrun simctl list devices available`. Supply a
selected simulator UUID to the test command:

```sh
xcodebuild -project Chadmux.xcodeproj -scheme Chadmux \
  -destination 'platform=iOS Simulator,id=SIMULATOR_UUID' \
  -derivedDataPath DerivedData CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES test
```

Replace `SIMULATOR_UUID` with the selected device ID. Use a distinct DerivedData
folder for each task worktree: sharing build products can reuse stale test bundles.
Simulator tests must be ad-hoc signed (`CODE_SIGN_IDENTITY=-`), since unsigned
bundles cannot exercise Keychain. Do not require a paid team for simulator tests.
Unit tests verify trust policy, real Keychain persistence, saved settings and
bounded response parsing. XCUITest checks validation and relaunch persistence.
The opt-in disposable SSH probe in `docs/ssh-terminal-foundation.md` additionally
checks the app's unknown/changed-key flow, PTY, forwarding, two-tab routing,
Unicode session names, detach and stale-ID refusal after a tmux restart. A default skip is
not transport evidence. There is no separate lint setup.

API forwarding sends only `/transcriptions` to remote `127.0.0.1:8420`. Its scoped
bearer token must stay in Keychain. The bounded client expects the companion server's
HTTP/1.1 Content-Length JSON contract; no redirects or arbitrary URLs are used.
Transcription failure does not close the SSH connection. Physical iPhone Tailscale
reachability and keyboard/resize readability remain integrated-pilot validation.

## Composer and session readiness

Send supports multiline UTF-8 up to 64 KiB. It rejects terminal control characters
except newline/tab and writes a bracketed paste plus Enter as one message. It does
not interpolate draft text into a shell command or infer Claude receipt from a
local write. Only send when the intended application is ready at the remote prompt.
The app confirms its exact tmux client PID/session instance before enabling input;
a login shell's paste mode alone is not attachment readiness.

A send captures the originating tab. Duplicate taps are disabled. Successful local
transmission clears the draft only if it has not changed; errors retain it and
require an explicit acknowledgement after inspecting the terminal before retrying.
No automatic replay occurs. Offline tabs remain editable. Eligible foreground resume reconnects only the selected session; it never sends restored content. Actual Claude prompt/paste interpretation remains
part of the hardware pilot while Claude usage is unavailable.

## Photos and retention

Select up to eight camera/library images per message. ImageIO decodes raster
formats such as JPEG, PNG and HEIC (the first frame of animated images), then
normalizes orientation and writes JPEG with a maximum 2048-pixel edge. Source
inputs are limited to 32 MiB and converted images to 5 MiB each. Metadata is
stripped. Local copies use generated UUID names, complete file protection and
backup exclusion. Originals in the photo library are not modified or deleted.

Local copies remain until explicit removal/discard or successful local terminal
transmission. Upload or uncertain-send failure retains them with the draft.
Referenced images survive relaunch; unreferenced generated local images are cleaned at startup after all saved archives are read successfully.
Camera denial and library cancellation do not submit or discard anything.

SFTP creates private UUID batches under `~/.chadmux/uploads` on the Mac (700
directories, 600 files). Source filenames never become remote paths. All required
uploads finish before one literal text-and-quoted-path submission. A failed batch
submits nothing; best-effort cleanup can leave an orphan after a disconnection.
Uploads use a short-lived **separate SSH connection** with the same saved device
key and verified host pin. Citadel does not expose the SFTP child until version
negotiation completes, so owning the upload connection first permits cleanup even
when that negotiation stalls. This deliberately replaces the initial connection-
reuse default; no new server, credential or public transport is introduced. A
cancelled or timed-out upload closes its own SSH transport, never the terminal.

Remote batches are retained until **manual deletion on the Mac**, including after
a successful send. There is no automatic expiry that might break a resumed Claude
conversation. Periodically inspect `~/.chadmux/uploads` in Finder and delete batches
only when their conversations no longer need the images; this also removes any
interrupted-upload orphans. The app explains this retention policy in settings.
No private content or SFTP paths are sent to application logs. Actual camera/library
permissions and Claude reading multiple uploaded paths remain hardware-pilot checks.

## Dictation

One recording at a time, using AAC M4A, mono 16 kHz at 32 kbit/s, with a two-minute
maximum. Tap the microphone again or Stop to finish; Cancel, audio interruption,
backgrounding or closing the originating tab discards the recording. Audio uses
protected temporary files excluded from backup, removed after stop/cancellation or
failure; abandoned audio is removed at the next process launch. No audio is
recorded automatically and no transcript is submitted automatically.

Choose the **dictation host** under Connection settings (the first host by
default) and save the dedicated companion-server transcription token on that host. Dictation
from a tab on any host goes to the dictation host's loopback `/transcriptions`
(its resident whisper.cpp small.en model): over that host's live SSH connection,
or, if it isn't connected, a pinned SSH connection opened for that one request and
closed afterwards. It never trusts a new host key: connect to the dictation host
once to verify it. Before recording starts, a missing host, token or verified key
is reported and nothing records. A planned follow-up moves this to
the companion server's Tailscale Serve URL. SSH and typed input work independently of the API. Missing token, microphone denial, busy/unavailable service and failed
requests show recovery instructions without logging audio, tokens or transcripts.
Failed/cancelled audio is discarded; retry means explicitly recording again.

The insertion location in v1 is the **end of the originating draft**, as announced
by the microphone accessibility hint. If the draft changes while recording or
transcribing, an editable transcript offers Insert/Discard instead of overwriting
those changes. Switching tabs leaves the result with its origin. A global activity
bar identifies that origin and permits Stop/Cancel from another tab.

The agreed warm target is **text ready to edit within two seconds after stopping
recordings up to 30 seconds**, with the Mac awake and the model loaded. This is a
performance target, not a timeout or a guarantee over a mobile connection. The
client's bounded request timeout remains 120 seconds; cancellation closes only
its request channel. Hardware microphone quality and stop-to-edit latency over
Tailscale require the phone pilot.

For an opt-in real resident-service test, run `scripts/test-transport.py` with
`--resident-token-file /path/to/private-scoped-token` in addition to its normal
simulator arguments. The file contains only the transcription token, with mode
600, and is not committed. The harness generates invented speech with macOS
`say`, encodes M4A, and sends it through disposable SSH to the already-running
companion server API on port 8420. It reports first and subsequent timings without printing
the token or response content. It does not start/reconfigure services or use a
microphone. Ordinary tests use injected recording/response boundaries instead.

## Recovery and local retention

Drafts, attachment references, pending transcripts, selected tab and uncertainty
are saved atomically after changes under Application Support with complete file
protection and backup exclusion. Snapshots are separated by exact saved Mac/user
profile and retain the tmux server/session instance, not only its reusable ID.
No credentials, raw recordings or terminal scrollback are included. Drafts stay
until explicitly discarded/closed or successfully transmitted locally; a completed
transcript remains in the draft. Unreferenced generated local images are removed
at startup only after every archive can be read. A corrupt or locked archive
prevents cleanup and is never silently overwritten.

Relaunch restores local tabs first. After a successful explicit Connect on this
version, foreground return automatically reconnects the selected previously
attached session; other tabs attach when selected. Legacy archives stay offline
until that explicit Connect. Missing/replaced sessions retain their draft and
images; close/discard the old tab only when those are no longer needed. Nothing
records, uploads or submits automatically. Backgrounding cancels media work,
saves drafts and closes phone SSH clients; it never kills the Mac's tmux sessions.
Disconnect explicitly disables automatic resume, including after relaunch.
Force quitting does not revoke saved intent; the next explicit launch may resume.

A foreground cycle makes at most two attempts, retrying transient failures after
two seconds, with a thirty-second total deadline. Unknown host keys require
verification; changed keys, authentication failures and missing/replaced sessions
are not retried automatically. Network loss while already active offers Retry;
there is no continuous retry loop. Protected recovery/Keychain remain unavailable
while locked. Resume waits for unlock, preserves drafts and uncertainty, and never
replays input. The keyboard and native text-selection overlay stay dismissed.

Before terminal submission, a durable `writeInFlight` checkpoint retains the full
draft/images. A process exit at or after that point restores an uncertain send
requiring terminal inspection and explicit acknowledgement before retrying. A
successful local write commits updated draft/media state before deleting sent
local images. Storage failure before a write prevents sending; failure after a
write retains the evidence and reports uncertainty. Save failures are visible;
unlock the phone/check free space and preserve in-memory edits before closing.
Snapshots allow up to eight tabs, 1 MiB of draft text per tab and 10 MiB total;
Send still has its stricter 64 KiB message limit. Oversize state fails visibly.

Terminal dimensions follow the selected session's existing tmux window-size
policy; Chadmux sends its PTY dimensions and does not alter the user's server
configuration. The disposable desktop/phone fixture explicitly uses `latest` and
verifies client resize and detach while the desktop remains attached. Readability
with the actual Mac configuration and iOS suspension remain phone-pilot checks.

## Deployment and data

Local physical-device delivery is supported through a locally selected development
team; signing credentials are not stored in this repository. TestFlight/App Store
distribution remains a later milestone. Follow `docs/ios-development.md`. Do not
commit signing credentials, real SSH hosts or private connection details.
Simulator checks do not authorize deployment. Camera permission is requested only on camera use; library selection uses the
system picker without broad library permission. Microphone permission is requested only when recording is started.

## Creating and ending sessions

The sidebar's **+** asks for a name (`[A-Za-z0-9_-]`, at most 64 characters) and
a folder on the Mac, prefilled with the last folder used for that Mac (`~` at
first). **Create** runs `claude-tmux create NAME --dir FOLDER`, refreshes the
list and opens the new session in a tab; with eight tabs open it refuses before
contacting the Mac. Script errors (name taken, folder missing, `claude` not
found) appear verbatim in the sheet, which stays open for correction.

Each listed session row has a **−**. It confirms with an alert that names the
session and host, with Cancel as the default, then runs `claude-tmux close NAME
--id ID --instance PID:CREATED` using the exact session Chadmux listed. A session
replaced since the last refresh is refused rather than killed (ids alone repeat
after a tmux server restart; the instance does not). An open tab on an ended
session stays, marked missing, with its unsent draft until you close it.

Chadmux never reimplements session creation. It runs the installed script
`~/.claude/scripts/claude-tmux.sh` through the user's login shell (`$SHELL -lc`)
so `claude` is on `PATH`, with Homebrew's tmux directories prepended. Every
argument is single-quoted for both shell layers. The script prints one JSON line
and a distinct exit status; because Citadel discards output on a non-zero exit,
the remote command always reports that status after a `\x1e…\x1f` marker.
Install the script on each host from a clone of [github.com/Ascinocco/q-factory-clean](https://github.com/Ascinocco/q-factory-clean) with `scripts/install-claude-tmux.sh`;
without it, Create explains that it is not installed.

`--multi-ui` runs the multi-host sidebar XCUITest: two hosts backed by separate
tmux servers behind the disposable sshd (each with a session of the same name)
and an offline host on a closed port.

`scripts/test-transport.py` passes `--claude-tmux PATH` (default: the installed
script) to the disposable fixture, which adds a `tmux` wrapper for its private
server and a fake `claude` that only reports its folder. `--manage-ui` runs the
create/end XCUITest; the SSH integration suite includes the create/end test.
Both skip, not pass, when no script is available.

## Hosts

Chadmux keeps up to eight saved hosts, each with a label (such as Mac or Arch),
a Tailscale address, SSH port and username, and a default folder for new
sessions. Add, edit and remove them under **Connection settings**. A host's
address, port and username are locked while it has open tabs; removing a host
asks first, then closes its tabs (discarding their unsent drafts) and forgets its
host key and transcription token unless another host uses the same address.

The sidebar lists every host under its own heading, with a status line
(Connected, Reconnecting…, Offline and so on), a Connect button when it is not
connected, and its own **+** (new Claude session), refresh and session rows with
**−** and tab close. An unreachable host shows as Offline, with its error in its
own section, and never blocks the others. Tapping a session on any host puts that
host on screen; the title shows the tab's host under the session name. Tabs on
different hosts stay open together, and the same session name on two hosts is two
separate tabs. The selected host and the sidebar's state are remembered.

Each host has its own SSH connection, session list, tabs, drafts, recovery
archive, foreground resume and pinned host key. The endpoint (address, port and
username) is the key for all of those, exactly as the single saved connection was,
so upgrading migrates that connection into a host called **Mac** with its pinned
key, drafts and resume choice intact: no re-pairing. The old saved value is left
in place. One device key serves every host. The eight-tab limit spans all hosts,
and there is one microphone: dictation belongs to one tab, and only that tab's
host disconnecting stops it.

Hosts are reached with OpenSSH over the tailnet. Do not enable Tailscale SSH on a
host Chadmux uses: it would take over tailnet port-22 connections and ignore the
per-device keys Chadmux relies on. The host must also allow an AES-GCM cipher
and the `hmac-sha2-256` MAC. Chadmux offers only swift-nio-ssh's built-in
aes256/aes128-gcm, and swift-nio-ssh requires a MAC match even for AES-GCM,
offering exactly `hmac-sha2-256` as a placeholder. Session listing runs tmux with a fixed PATH
(`/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin…`), so NixOS hosts need tmux
linked into `/usr/local/bin`. See [the host runbook](docs/runbooks/hosts.md).

## Linux hosts

Hosts can be Linux (the Arch server) as well as macOS: the tmux commands, format
strings, client-PID and instance checks, bracketed paste, resize, SFTP uploads to
`~/.chadmux/uploads`, and `claude-tmux create`/`close` through the host's login
shell (bash on Arch) are exercised against a disposable Linux host in the test
suite. Linux hosts run OpenSSH with key-only authentication; `claude-tmux` comes
from a clone of github.com/Ascinocco/q-factory-clean on the host (`scripts/install-claude-tmux.sh`).

`scripts/test-transport.py --linux` builds `scripts/linux-fixture` (Fedora with
OpenSSH, tmux 3.7 and bash as the login shell, native on Apple silicon) and runs it
under Docker as the primary host: the SSH/tmux/paste/resize/SFTP/claude-tmux/
resume/changed-key integration tests, plus dictation from a Linux tab through the
macOS fixture as the dictation host. With `--linux --multi-ui`, the multi-host UI
test's "Arch" host is that container and "Mac" is the macOS fixture. It is not
Arch itself: Arch's official image is x86-only, and under Docker's x86 emulation
OpenSSH's seccomp sandbox cannot start. Arch specifics are covered by the pilot on
the real Arch host. The fixture folder is copied into the container at the same
path, owned by the SSH user (tests reach it only over SSH/SFTP); tmux sockets live
in the container's /tmp. Docker must be running; the container is removed after.

## macOS app

A native macOS target, `ChadmuxMac`, builds the app **Chadmux** (`Chadmux.app`; macOS 15 or later: Citadel's PTY API requires
it), shares the non-UI code with iOS: SSH and trust, hosts, tmux sessions,
`claude-tmux`, the composer model, drafts and recovery, photo upload and dictation.
The iOS-only pieces are the UIKit terminal view, the iOS screens, the photo picker
and the audio session; their Mac equivalents arrive story by story (Chadmux epic
e03adea2).

The transport talks to its terminal through `TerminalScreen`, so the same
`MacTransport` drives SwiftTerm's UIKit view on iOS and its AppKit view on macOS.
The Mac module is named `Chadmux`, so the same `@testable import Chadmux` unit tests
run on both platforms: `ChadmuxMacTests` includes the host, `claude-tmux`, composer,
connection/Keychain and dictation tests.

**The session window** (`MacWorkspaceView`) follows cmux: flat dark panels, no
title bar, and a sidebar of vertical tabs as the main navigation. Sessions are
grouped under each host (status dot, Connect, refresh and + as quiet icons; more in
the host's context menu). Each row shows the session's folder and other attached
clients (read best-effort from tmux, display only). Open tabs carry a dot, and the
selected tab is highlighted; hover shows × (close the tab, never ends tmux) and −
(end the session, confirmed). A slim header names the session, host and folder
over the full-bleed terminal (SF Mono). The window's close/minimize/zoom
buttons share the top line with the sidebar's collapse button (also View ›
Hide Sidebar, Ctrl-Cmd-S; the Mac remembers it, shown by default). The Sessions menu has **New Claude
Session…** (Cmd-T, on the host on screen, else the first connected one), **Close
Tab** (Cmd-W; closes at once, since the Mac has no drafts, and never ends the tmux
session), **Previous/Next Tab**
(Ctrl-Cmd-[ and ]), **Show Tab 1–8** (Cmd-1…8, in sidebar order, crossing hosts)
and **Refresh All Hosts** (Cmd-R). Tabs, drafts and the selected host are
restored on relaunch, and returning to the app resumes connections, as on iOS.
There is one window; the window's Close gives Cmd-W to Close Tab.

**No input bar on the Mac.** You type into Claude directly in the terminal, as in
cmux; the iPhone keeps its composer. Images reach Claude on any host the way a
local terminal hands over a dropped file: **drop** image files or images onto the
terminal, or **⌘V** with an image on the clipboard (a text paste is left to the
terminal). Chadmux uploads each image over SFTP to the session's host, re-encoded
without metadata and owner-only in `~/.chadmux/uploads/<batch>/`, then pastes the
absolute remote path(s) into the pane as a bracketed paste with a trailing space and
no Enter (`TerminalImageDrop`). Claude on the host shows them as `[Image #N]`
(checked with Claude Code 2.1 through tmux), exactly as it does for a local drop.
The session header shows the upload's progress and any error. A drop never skips
silently: a non-image or an image over 32 MiB is reported, and in a mixed drop the
images are added and the skipped items counted. A drop or paste that arrives during
an upload is queued and handled after it.

**Dictation on the Mac** (`MacDictation.swift`): a **Dictate** mic sits in the
terminal's bottom-right corner whenever the tab is connected, with **Live** to its
left when scrolled back; Terminal › Dictate / Stop Dictation is Shift-Cmd-D
(Option-Cmd-D is the system's Dock shortcut). Click to record with this Mac's
microphone (permission is asked on first use), click again to stop. The shared
`VoiceCoordinator` records and sends the audio to the **dictation host** exactly as
on the iPhone (see [Dictation](#dictation)); its `deliver` hook, set only on the Mac,
then pastes the transcript into the origin tab's terminal instead of a draft
(`TerminalDictation`): whitespace runs, newlines included, become one space, every
other control character (ESC, C0, DEL, C1) is dropped, and the line is sent as one
bracketed paste (when the remote asks) with a trailing space and **no Enter**, so it
waits in Claude's input to edit. Audio never leaves the Mac except to the dictation
host; only the text reaches the session's host, so This Mac and server sessions work
the same. Esc or × discards (nothing is pasted); so do closing the tab and a host
disconnect. Errors (microphone off, no dictation host or token, transcription
failure, the session disconnected) show in the session header, and nothing is
pasted. One recording at a time: the mic is disabled in other tabs while one records.
Claude Code's own push-to-talk still records on the machine Claude runs on.

The Mac terminal is SwiftTerm's AppKit view (`MacNativeTerminalView`), shown with
`MacTerminalSurface`. It sends Ctrl and arrow keys, the tmux prefix and Option as
Meta. **Copy and paste:** while tmux has the mouse (`mouse on`) a drag selects in
tmux, and tmux's copy arrives as OSC 52, which Chadmux puts on the Mac clipboard.
Shift-drag makes a selection in the terminal itself, which Cmd-C copies. Cmd-C
with no terminal selection leaves the clipboard alone; SwiftTerm's default
emptied it. Cmd-V pastes the clipboard's text, bracketed when the remote asks, and
drops any embedded end-of-paste marker. The host can set the clipboard but never
read it.
While tmux reports the mouse (`mouse on`), the wheel and trackpad go to it, as on
iOS, so tmux scrolls its own history and **Return to Live Output** (Cmd-Option-Down)
leaves it. The Terminal menu adds **Clear Screen** (Cmd-K: clears only this view and
asks tmux to redraw this client; remote history is untouched) and **Find** (Cmd-F).
Resizing the window resizes the PTY.

`scripts/test-transport.py --mac` runs the real-SSH integration suite natively on
macOS against the disposable sshd, and `--mac --linux` against the Linux container.
It signs with the team in `CHADMUX_DEVELOPMENT_TEAM` (never committed).
`--mac --multi-ui` and `--mac --manage-ui` run the Mac window's UI tests
(`ChadmuxMacUITests`, scheme `ChadmuxMacUI`) against the same live fixtures as the
iOS ones: grouped hosts with an offline one, the same session name on two hosts,
+ and − per host, a replaced session refused, and the Cmd-T/W/R/1…8 shortcuts.
They drive the real desktop (the first run asks to allow the test runner in
System Settings › Privacy & Security › Accessibility), so they are kept out of
the default `ChadmuxMac` test action. Add `--linux` to make "Arch" the container. The offline UI tests
(no input bar, window buttons and sidebar) need no fixture: run the `ChadmuxMacUI`
scheme. Under `--ui-testing` the app reads pasted images from a private test
pasteboard, never your clipboard; `--manage-ui` pastes one into a live session and
checks it is uploaded and pasted. With `--mac`, `--manage-ui` also runs the dictation
test: an injected recorder (the microphone is never opened) and transcriber, the
transcript pasted into a live `cat` pane once with no Enter (Esc and × paste nothing),
and Live still working beside the mic. Result bundles from these runs contain a
recording of the whole screen, so delete them after use.

**Hosts on the Mac.** Host Settings (Cmd-,) is the same host list and editor as on
iOS. The first host offered is **This Mac** (`localhost`, your username): the Mac
reaches itself over its own OpenSSH, so turn on Remote Login (System Settings ›
General › Sharing, allowing your user only) and add the Mac app's public key to
`~/.ssh/authorized_keys`. The Mac has its own device key, separate from the
phone's, so either can be revoked. **Check SSH** in the host editor reads the
host's SSH banner without logging in: it reports when nothing answers (with the
Remote Login hint for this Mac) and warns when Tailscale SSH answers instead of
OpenSSH. On macOS, drafts and images are stored owner-only (directories 0700,
files 0600), since macOS has no per-file protection classes.

On macOS the Keychain is the data-protection keychain (as on iOS), which needs the
app signed with a team and its keychain access group (`ChadmuxMac.entitlements`).
Pass your local team on the command line; never commit it.

**Installing:** `CHADMUX_DEVELOPMENT_TEAM=YOUR_TEAM scripts/install-mac.sh` builds a
signed Release into one temporary folder (deleted afterwards), installs
`/Applications/Chadmux.app` and keeps the previous copy for `--rollback`; data and
Keychain items carry over. See [docs/mac-install.md](docs/mac-install.md) and the
[Mac pilot](docs/mac-pilot.md). `scripts/test-install-mac.py` tests the script.
For development builds, use one DerivedData folder and delete it afterwards:

```sh
xcodebuild -project Chadmux.xcodeproj -scheme ChadmuxMac \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/chadmux-mac \
  DEVELOPMENT_TEAM=YOUR_TEAM CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates test
```

## Coordination

An external factory coordinates the project's Jyra work queue. Task handoffs provide board,
ticket and shared procedure context; project guidance contains no absolute
factory paths or private records. The first useful version is specified in
[docs/first-useful-version.md](docs/first-useful-version.md). It describes planned
work; the implementation and commands above describe the currently delivered subset.

## Foreground resume

[Foreground resume specification](docs/foreground-resume.md) contains research,
behavior contracts, acceptance scenarios and the linked Jyra epic/tickets for
automatic reconnect on reopening. The implementation is a candidate pending
physical-device acceptance. Run `scripts/test-transport.py --resume-ui --simulator
SIMULATOR_UUID` for real SSH warm-return, cold-relaunch and opt-out UI checks.

## Terminal touch gestures

Swipe down directly inside a tmux pane for older output; swipe up for newer
output. Movement sends scroll-wheel events at the touched terminal cell, so tmux
or an application such as Claude handles its own history. No touch mode or resize
bar is required. tmux mouse support must be enabled for the session; Chadmux
reports when wheel input is unavailable and does not change global tmux options.
Custom wheel bindings determine how many lines each tick moves. Swipes use a
responsive wheel cadence with momentum for longer travel; touching the terminal
stops the glide immediately for precise positioning.

The small down arrow returns the active tmux pane from copy mode to live output.
It uses a guarded tmux command and never sends Escape to the running application.
If the application maintains its own history instead of tmux copy mode, swipe up
to its newest output; the arrow does not send application-specific shortcuts.

Long-press (or double-tap) text to select it with iOS handles and Copy. Chadmux
freezes the touched pane's visible text in a native, read-only selection view,
keeping adjacent panes out of the selection. Copy places only the selected text
on the iPhone clipboard and closes selection; the small X cancels selection.
Paste normally into the composer and review before Send. The snapshot is not
saved or logged. Lines explicitly redrawn by tmux retain their visible line
breaks; Chadmux does not infer how a remote command should be rejoined.

Run `scripts/test-transport.py --native-ui --simulator SIMULATOR_UUID` for the
live disposable SSH/tmux swipe → native Copy → exact Paste → live-return check.
It never connects to personal tmux sessions. The normal transport suite also
checks two-pane wheel targeting, guarded live return and reconnect behavior.
Physical-device gesture feel still needs the iPhone pilot; passing simulator
checks is not a claim of physical acceptance. Pane resizing is deferred.
