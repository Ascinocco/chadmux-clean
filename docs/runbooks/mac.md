# Running Chadmux on the Mac

The Mac app is `/Applications/Chadmux.app` (bundle id `com.ascinocco.chadmux.mac`,
macOS 15+), a team-signed local Release build. It is not notarized or
distributed. Detail on the installer: [mac-install.md](../mac-install.md).

## Install, update, roll back

From a clean checkout (or task worktree) at the commit you want:

```sh
CHADMUX_DEVELOPMENT_TEAM=YOUR_TEAM scripts/install-mac.sh   # install or update in place
scripts/install-mac.sh --rollback                           # previous copy back (run again to undo)
```

- Set `CHADMUX_PACKAGES=/path/to/SourcePackages` to reuse resolved SwiftPM
  checkouts and save a download.
- The script builds into one temporary folder (always deleted), refuses a bundle
  that isn't Chadmux or doesn't verify, quits the running app politely, keeps the
  old copy for rollback and appends to
  `~/Library/Application Support/Chadmux/install/history.tsv`. A dirty checkout is
  recorded as `<commit>+dirty`.
- Updates keep the device key, pinned host keys, hosts, drafts and sidebar state.
  Nothing needs re-pairing.
- After installing a PR build for the owner to test, say which commit is installed.

## First-time setup

1. **Host Settings** (Cmd-,). The first host offered is **This Mac**
   (`localhost`, your username). The Mac reaches itself through its own OpenSSH:
   System Settings › General › Sharing › **Remote Login** on, allowed for your
   user only.
2. Copy the **Mac app's public key** (its own device key, separate from the
   phone's) into the host's `~/.ssh/authorized_keys`. For This Mac that is your
   own `~/.ssh/authorized_keys`; for a declaratively managed server, add it through its configuration.
3. **Check SSH** in the editor reads the host's SSH banner without logging in.
   It reports "nothing answered" (with the Remote Login hint for This Mac) and
   warns if Tailscale SSH answers instead of OpenSSH.
4. Connect and verify the fingerprint as on the iPhone.

Add a server (or any other host) the same way: label, Tailscale name, port 22,
username, default folder. The host itself must meet [hosts.md](hosts.md).

## Daily use

The window follows cmux: a sidebar of hosts and their sessions on the left and
the full-bleed terminal on the right, with a slim header naming the session,
host and folder.

| Action | How |
| --- | --- |
| New Claude session | **+** on the host, or Cmd-T (host on screen, else the first connected) |
| Rename a session | pencil on the row, the row's context menu › Rename…, or Sessions › Rename Session… |
| End a session | **−** on the row (confirmed); ends the tmux session |
| Close a tab | × on the row or Cmd-W; closes immediately and never ends tmux |
| Switch tabs | Ctrl-Cmd-[ / ], or Cmd-1…8 in sidebar order |
| Refresh all hosts | Cmd-R |
| Hide/show the sidebar | the collapse button, View › Hide Sidebar, Ctrl-Cmd-S |
| Clear this view | Cmd-K (asks tmux to redraw; remote history untouched) |
| Find | Cmd-F |
| Leave tmux history | Cmd-Option-Down (Return to Live Output) |
| Dictate into Claude's input | the mic (bottom right) or Shift-Cmd-D; again to paste, Esc to discard |

**Typing:** there is no input bar. Type into Claude in the terminal. Ctrl, the
arrow keys, the tmux prefix and Option-as-Meta all go through.

**Copy and paste:**
- **Copy:** drag to select. With tmux `mouse on` the selection is tmux's, and
  releasing the mouse copies it to the Mac clipboard (tmux sends it as OSC 52).
- **Terminal selection:** hold **Shift** while dragging to select in the terminal
  itself, then press Cmd-C.
- **Cmd-C with nothing selected** in the terminal leaves the clipboard as it was.
- **Paste:** Cmd-V pastes text, bracketed when the remote asks, so Claude gets it
  as one paste.

**Images:** drop image files or images onto the terminal, or ⌘V with an image
on the clipboard. Chadmux uploads each one over SFTP to the session's host
(`~/.chadmux/uploads/<batch>/`, re-encoded without metadata, owner-only) and
pastes the absolute remote path with a trailing space and **no Enter**. Claude
shows it as `[Image #N]`; press Enter when your prompt is ready. The header shows
"Uploading image…", "Added image to the prompt", and anything skipped (not an
image, or over 32 MiB). Up to 8 at a time; a drop during an upload waits its turn.

**Dictation:** click **Dictate** (the mic in the terminal's bottom-right corner,
or Shift-Cmd-D), speak, then click it again. The first time, macOS asks for the
microphone. The audio is recorded on this Mac and transcribed by the **dictation
host** (Host Settings › Dictation, with that host's transcription token), the same
route the iPhone uses; the text is pasted into Claude's input with **no Enter**, as
one line (newlines and control characters removed). Edit it, then press Enter.
Works for This Mac and server sessions alike. Esc or × discards the recording and
pastes nothing. Problems (microphone off, no token, transcription failed, the
session disconnected) show in the session header. Claude Code's own push-to-talk
(hold Space) records on the machine Claude runs on, so it only suits This Mac.

**Scrolling:** with tmux `mouse on`, the wheel/trackpad scroll tmux history.

State (tabs, selected host, sidebar) is restored on relaunch, and returning to
the app resumes connections.

## Removing

Quit Chadmux, delete `/Applications/Chadmux.app` and
`~/Library/Application Support/Chadmux/install`. To remove its data too, delete
the `com.ascinocco.chadmux` Keychain items and the Mac key's line in each host's
`authorized_keys`.

Problems: [troubleshooting.md](troubleshooting.md).
