# Mac pilot

The Mac app installed with [the install runbook](mac-install.md), used on
the owner's Mac with real sessions. Use invented prompts, not private projects,
for anything recorded here. Status markers: ✅ passed, ⏳ pending (who), ➡️ moved.

| Scenario | Action | Required result | Result |
|---|---|---|---|
| Install | `scripts/install-mac.sh` from a clean checkout | `/Applications/Chadmux.app`, icon in Finder and the Dock, build folder deleted | ✅ 2026-09-25: installed f751b99, signature verified, build folder removed, launched |
| Update in place | Run the script again after a change | Hosts, trust, token and drafts kept; no re-pairing | ✅ 2026-09-25: f751b99 → 33040cf in place, running app quit and relaunched, hosts kept |
| Rollback | `--rollback`, then `--rollback` again | Previous copy back, then undone; data kept | Covered by `test-install-mac.py` |
| This Mac as a host | Host Settings: add This Mac, Check SSH, Connect, trust the fingerprint | OpenSSH over Remote Login with the Mac app's own key; Tailscale SSH not involved | ✅ 2026-09-25 (owner). Key login also verified against the pinned host key |
| One-click session | **+** on This Mac, name and folder, Create | A live Claude session opens in a tab, in that folder | ✅ 2026-09-25 (owner, installed app) |
| End a session | **−** on that session, confirm | The session ends; an open tab keeps its draft | ✅ 2026-09-25 (owner, installed app) |
| Continue on the iPhone | Open the same session from the phone (Mac host) | The same tmux session, with both clients attached; sizing follows the active client | ✅ 2026-09-25 (owner) |
| Dictation from the Mac microphone | Mic in a Mac tab, allow the prompt, speak, stop, insert, Cmd-Return | Editable transcript; nothing sends until Cmd-Return | ✅ 2026-09-25 (owner, real microphone) |
| Look and feel | Use the Release build | The cmux-style window is accepted | ✅ 2026-09-25 (owner, story 7) |
| Server host (Linux/NixOS) | Add the server on the Mac and the iPhone | As in the Multiple hosts row of the iPhone pilot | ✅ Mac 2026-09-25 (owner): connects, creates, lists and opens sessions, after the server's sshd MAC and tmux-path changes. ⏳ iPhone (owner) |

## Install history

| Date | Action | Commit | Notes |
|---|---|---|---|
| 2026-09-25 | install | f751b99 | First install from the runbook; replaced the /tmp preview. Hosts, trust and token carried over (same bundle id and team) |
| 2026-09-25 | install (update) | 33040cf | JetBrains Mono terminal font; updated in place over f751b99 |
