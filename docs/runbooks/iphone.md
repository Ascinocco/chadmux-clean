# Running Chadmux on the iPhone

The iPhone app is a local development build installed from Xcode tooling (no
TestFlight yet). It keeps its data across installs as long as the bundle id
(`com.ascinocco.chadmux`) and signing team stay the same.

## Install or update a build

Build from a clean task worktree at the commit you mean to install. Full detail
and background: [ios-development.md](../ios-development.md).

```sh
xcrun devicectl list devices                     # find the paired phone
CHADMUX_DEVICE='PAIRED_DEVICE_IDENTIFIER'
CHADMUX_TEAM='LOCAL_DEVELOPMENT_TEAM'            # never committed
BUILD=/tmp/chadmux-device-$(git rev-parse --short HEAD)

xcodebuild -project Chadmux.xcodeproj -scheme Chadmux \
  -destination 'generic/platform=iOS' -derivedDataPath "$BUILD" \
  DEVELOPMENT_TEAM="$CHADMUX_TEAM" CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY='Apple Development' -allowProvisioningUpdates build

xcrun devicectl device install app --device "$CHADMUX_DEVICE" \
  "$BUILD/Build/Products/Debug-iphoneos/Chadmux.app"
xcrun devicectl device process launch --device "$CHADMUX_DEVICE" com.ascinocco.chadmux
rm -rf "$BUILD"
```

- Install **in place**. Never uninstall, or change the bundle id or team, as a
  troubleshooting step: that throws away the device key, pinned host keys,
  tokens and drafts, and every host's `authorized_keys` entry stops matching.
- "Launch refused because the device is locked" usually means the install
  worked: unlock the phone and open Chadmux by hand.
- A merge or a factory pointer update does **not** install anything. Record what
  you installed (commit, date) in the PR or ticket.

## First-time setup on a phone

1. **Connection settings** opens straight into adding a host the first time.
   Enter a label (Mac, server…), the host's Tailscale name or address, the SSH
   port (22) and the username, plus a default folder for new sessions (`~`).
2. Copy **this phone's public key** from settings and add that one line to the
   host's `~/.ssh/authorized_keys` (see [hosts.md](hosts.md); on a declaratively
   managed server, add it through its configuration). The private key never leaves the Keychain.
3. Tap **Connect**. Compare the fingerprint shown with the host's own
   (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on that host) before
   trusting it.
4. Optional: choose the **dictation host** and save its transcription token (see
   [Dictation](#dictation)).

Up to eight hosts can be saved. One device key serves them all.

## Daily use

- **Sidebar** (top-left icon): every host is a section with its status
  (Connected, Reconnecting…, Offline), a Connect button, **+** (new Claude
  session), refresh, and its sessions. Tap a session to open it in a tab. Tapping
  outside the sidebar only dismisses it.
- **Sessions:** **+** asks for a name (`A–Z a–z 0–9 _ -`, ≤ 64) and a folder, then
  runs `claude-tmux create` on the host. **−** ends a session after a
  confirmation. The **pencil** renames it (the tmux session itself, so every
  device sees the new name). Closing a tab only detaches this phone.
- **Tabs:** up to eight across all hosts. Each keeps its own draft, photos and
  transcript. The same session name on two hosts is two different tabs.
- **Composer:** type (multiline, up to 64 KiB), then **Send** pastes the text as
  one bracketed paste plus Enter. The terminal control row sends single keys
  (Enter, arrows, Tab, Esc, Ctrl-C). Swipe down on the composer to hide the
  keyboard. If the remote app hasn't enabled bracketed paste, Send refuses and
  keeps the draft.
- **Photos:** Camera or Choose photos (≤ 8 per message). Preview/remove before
  Send. Images upload over SFTP to `~/.chadmux/uploads/<batch>/` on the host and
  their paths are sent with the text.
- **Terminal gestures:** swipe inside a pane to scroll tmux history (needs
  `set -g mouse on`), the small down-arrow returns to live output, long-press
  or double-tap to select and Copy.
- **Background/foreground:** backgrounding closes the phone's SSH clients (tmux
  keeps running). Coming back reconnects the selected session automatically,
  unless you pressed Disconnect. Nothing is ever re-sent automatically.

## Dictation

Tap the microphone, speak, tap again (or Stop); the transcript lands at the end
of the originating draft for you to edit. Nothing is sent automatically. The
audio goes to the **dictation host's** loopback `/transcriptions` endpoint over
SSH.

> **Current state (2026-09-25):** the dictation endpoint was a companion server
> API on the Mac, which has since been stopped. iPhone dictation is
> unavailable until a planned follow-up points it at the Linux server's
> transcription service. Typing, photos and sessions are unaffected.

## Maintenance

- **Uploaded images** stay on each host under `~/.chadmux/uploads` until you
  delete them. Remove old batches when their conversations no longer need them.
- **Revoking this phone:** remove its line from each host's `authorized_keys`.
- **A host's key changed** (reinstall, new machine): Chadmux refuses to connect.
  Verify the new key on the host, then use **Forget trust** in that host's
  settings and connect again.
- **Removing a host** closes its tabs (discarding their drafts) and forgets its
  pinned key and token.

Problems: [troubleshooting.md](troubleshooting.md).
