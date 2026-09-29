# Troubleshooting

Find the message or symptom and follow the fix. Most problems are on the host or
the network, not in the app. [hosts.md](hosts.md) has the host checklist.

## Connecting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| "Could not reconnect to HOST. Check the host and Tailscale…" / "timed out", while `nc -z HOST 22` succeeds, and the host's sshd logs `Timeout before authentication` | **SSH algorithm mismatch.** swift-nio-ssh offers exactly one MAC, `hmac-sha2-256`, and the host doesn't allow it (NixOS's hardened default allows only `*-etm`) | add `hmac-sha2-256` to the host's sshd `Macs` ([hosts.md](hosts.md#ssh-algorithms)) |
| The same message, and `nc -z HOST 22` fails | Tailscale down on either end, host asleep, or sshd off | `tailscale status`; wake the host; for This Mac, turn on Remote Login |
| "SSH authentication to HOST failed…" | this device's key isn't in `authorized_keys`, or the username is wrong | copy the key from settings again. On a declaratively managed server, add it through its configuration |
| "Connection refused: HOST's SSH host key changed" | the host was reinstalled or replaced, or something is intercepting | verify the new key **on the host** (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`), then Forget trust and connect |
| Check SSH warns about Tailscale SSH | Tailscale SSH is answering port 22 | turn off Tailscale SSH for that host (`tailscale set --ssh=false`) |
| "Unlock your phone to access its SSH key" | Keychain is locked | unlock and retry |
| Mac: every Keychain operation fails right after a fresh build | the build isn't team-signed, so there's no keychain access group | build with `CHADMUX_DEVELOPMENT_TEAM` / `DEVELOPMENT_TEAM` |

## Sessions

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| "Could not list tmux sessions on HOST. Check that tmux is installed there…" (sshd shows the login succeeded) | tmux isn't in `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin` or `/bin` (NixOS) | link it into `/usr/local/bin` |
| + says `claude-tmux` isn't installed | no `~/.claude/scripts/claude-tmux.sh` on the host | run `scripts/install-claude-tmux.sh` from a clone of github.com/Ascinocco/q-factory-clean on the host |
| Create fails with "claude not found" | `claude` isn't on the **login** shell's PATH | fix the shell profile; check with `$SHELL -lc 'command -v claude'` |
| Rename says to update `claude-tmux` | the host has an older script without `rename` | reinstall it from github.com/Ascinocco/q-factory-clean |
| "This session ended or was replaced" | the tmux session was killed or recreated (ids repeat after a tmux restart) | refresh, then close the old tab (its draft is kept until you do) |
| No sessions listed, but `tmux ls` shows some | a different user or tmux socket on the host | check the host's username; Chadmux uses the default socket |
| Scrolling does nothing | tmux `mouse` is off | `set -g mouse on` in the host's `tmux.conf` |

## Sending, images and dictation

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| iPhone Send refuses: the app hasn't enabled bracketed paste | the pane isn't at an app prompt (for example a bare shell during startup) | wait for Claude's prompt; the draft is kept |
| "Delivery may have completed before Chadmux stopped…" | the connection dropped during a write | look at the terminal first, then acknowledge; never resend blindly |
| Mac drop: "Connect to HOST before adding images" | the tab isn't connected | Connect, then drop again |
| Mac drop: "Could not upload to HOST…" | SFTP failed | check the connection and disk space on the host |
| Mac drop: "Uploaded, but the connection … dropped before the path was pasted" | the file is on the host, but the paste never arrived | reconnect and drop again (the orphan in `~/.chadmux/uploads` can be deleted) |
| Mac: copying from the terminal gives nothing, or Cmd-V pastes nothing (before chadmux #37) | tmux's copy (OSC 52) was dropped, and Cmd-C with no terminal selection emptied the clipboard | update the Mac app. Drag-select copies through tmux; Shift-drag then Cmd-C copies locally |
| Mac: a drag-select doesn't reach the clipboard | the host's tmux has `set-clipboard off`, or the version is too old | `tmux show -g set-clipboard` should be `external` or `on` |
| Mac: a path shows as text instead of `[Image #N]` | Claude isn't at its prompt, or the path isn't an image file | drop again at Claude's input |
| Mac dictation: "Microphone access is off…" | the microphone permission was denied | System Settings › Privacy & Security › Microphone › Chadmux on, then click the mic again |
| Mac dictation: "Add the transcription token for HOST…" or "Connect to HOST once…" | the dictation host has no token, or its host key was never verified | Host Settings: pick the dictation host, save its token, connect to it once |
| Mac dictation: "The session disconnected before the text was pasted" | the tab dropped while transcribing | reconnect and dictate again; nothing was pasted |
| Dictation fails on the iPhone | since the 2026-09-25 cutover there's no transcription endpoint on the Mac | expected until Chadmux 791e82ec |

## Builds and tests

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| A test you expected to run shows as skipped | no fixture (`CHADMUX_TRANSPORT_FIXTURE`), a missing `--claude-tmux`, or a stale fixture key in the test's guard | run it through `test-transport.py` with the right mode, and read the skip reason in the log |
| Mac UI test can't type or click | the test runner isn't allowed under Accessibility | allow it in System Settings, then rerun |
| `test-transport.py --linux` hangs or fails early | Docker isn't running | start Docker Desktop |
| Old behaviour in tests after a change | DerivedData reused between worktrees | use a fresh DerivedData folder |
| Disk full during builds | leftover DerivedData, simulators or result bundles | [testing.md › Cleanup](testing.md#cleanup-every-time); `xcrun simctl delete unavailable` |
| Your terminal's tmux server vanished | a test ran `tmux kill-server` without `-S` inside a tmux pane | always `tmux -S <private socket>` and `env -u TMUX`. Sessions are gone; restart them |

## Looking at the host side

- A Linux host: `ssh USER@HOST journalctl -u sshd -f` while retrying from the app.
  `Accepted publickey … ED25519 SHA256:…` names the device key that logged in.
- This Mac: `log stream --predicate 'process == "sshd-session"' --info`.
