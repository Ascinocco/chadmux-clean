# First iPhone pilot

Status: implementation and automated checks are available; **physical product
acceptance is still pending**. Use invented prompts/images, not private projects
or documents. Claude usage must be available before claiming Claude-specific
paste/image acceptance. TestFlight remains a later milestone.

For building and installing the current candidate, use the
[local iOS delivery runbook](ios-development.md). Installation and product
acceptance are separate.

## Connect the phone

1. Open Chadmux's Connection settings. Enter the Mac's Tailscale hostname/IP,
   macOS username and SSH port (normally 22). Run Tailscale on both devices,
   enable macOS Remote Login, and keep the Mac awake.
2. Copy **this phone's public key** from settings. Add that single public-key
   line to your Mac's `~/.ssh/authorized_keys` without replacing existing keys.
   Keep `~/.ssh` mode 700 and `authorized_keys` mode 600. The private key stays
   in the phone's Keychain; do not transfer it or enter an SSH password.
3. Save and Connect. Independently compare the displayed fingerprint with
   `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the Mac before trusting.
   Unexpected host-key changes are refused; investigate before resetting trust.
4. Start/select two disposable tmux sessions on the same Mac/user used by SSH.
   The phone lists existing sessions and does not create them. Open the left
   sidebar to attach. Keep a desktop client attached too. Closing the phone tab
   detaches only its client; it does not end the remote session.
5. For dictation, set up the companion server's resident transcription service.
   Paste the **dedicated transcription token** into Chadmux settings; do not use
   the server's main bearer token. It stays in Keychain. The API and Whisper remain
   loopback-only; Chadmux forwards the request through authenticated SSH.

No private key, token, host configuration or phone provisioning data belongs in
Git, tickets, screenshots or test reports. There is no need to expose either
service publicly or add a webhook.

## Acceptance session

Record pass/fail and a short observation for each row. “Automated” below describes
supporting evidence, not a physical pass.

| Scenario | Phone/desktop action | Required result | Current evidence |
|---|---|---|---|
| Shared sessions | Attach phone and desktop, toggle sidebar, switch sessions, rotate, close a phone tab | Correct session, readable resize, remote session remains | Disposable SSH/tmux fixture; phone pending |
| Text and controls | Enter multiline synthetic prompt; use arrows, Tab, Esc, Enter, Ctrl-C at intended prompts | Literal text and correct interactive keys; one explicit Send | Exact bytes captured by fixture; Claude pending |
| Photos | Take/select three invented images, preview/remove one, Send two with text | Both retained images readable by Claude, no removed image sent | Real JPEG/SFTP bytes and permissions verified; camera/Claude pending |
| Dictation | Speak a short coding request, Stop, edit result, Send | Editable text, no automatic submission | Coordinator/UI plus resident AAC-over-SSH tests; microphone pending |
| Tab ownership | Switch tabs during recording/transcription/upload | Result and submission stay with originating tab | Injected/state and combined SSH tests; phone pending |
| Latency | Time Stop until editable text, model already loaded; repeat for 5–30s recordings | Aim for <=2 seconds; record actual values/network conditions | Local warm results below; phone pending |
| Failure isolation | With dictation unavailable, type/send normally; retry dictation explicitly after recovery | SSH/typing remain usable, clear dictation error | State/SSH fixture checks; phone pending |
| Recovery | Background/reopen, terminate/relaunch with drafts/photos, reconnect | Draft/media retained, selected eligible session resumes, no replay; Disconnect remains offline | Simulator and fault-injection coverage; foreground-resume hardware acceptance pending |
| Create session | Sidebar **+**, name a session, pick a real project folder, Create; then repeat with the same name and with a missing folder | New tab running Claude in that folder, the same as `claude-tmux new` on the Mac; inline name-taken and folder-missing errors | Real SSH/tmux fixture with the real script and a fake `claude`; phone pending |
| End session | **−** on a disposable session, Cancel, then End; also **−** on a session replaced on the Mac since the last refresh | Cancel changes nothing; End removes it and an open tab keeps its draft; replaced session is refused | Real SSH/tmux fixture; phone pending |
| Multiple hosts | Add the Arch host (OpenSSH, Tailscale SSH off, this phone's key authorized); open sessions on both hosts, including the same name on each; take one host offline | Both grouped in the sidebar; tabs on both stay open with the right host shown; the offline host shows Offline without blocking the other | Disposable macOS + Linux (Fedora) container fixtures; phone and real Arch host pending |
| Dictation host | With the Mac as dictation host, dictate from an Arch tab, with and without a Mac tab connected | Transcript arrives in the Arch tab's draft; nothing auto-sends | Fixture test of both connection paths; microphone pending |
| Uncertain send | Observe a controlled interrupted write; inspect terminal before acknowledging | Retained draft, explicit choice to retry, no duplicate replay | Pre/post-write persistence/fault injection; real network loss pending |

A successful local terminal write does **not** prove Claude received or understood
the prompt/images. Check the remote conversation before accepting that scenario.
Do not rerun an uncertain message just to see whether it works.

## Automated evidence and limits

Use `PROJECT.md` for build/test commands and `docs/ssh-terminal-foundation.md` for
the disposable SSH runner. Fixtures generate their own keys, loopback sshd and
private tmux socket; they do not inspect or mutate personal tmux panes. The
combined scenario uses synthetic recorder input and a fixture transcription API,
then real SFTP, terminal submission and persisted recovery. A separate opt-in
resident probe uses synthetic AAC and the actual already-running companion server.

On the development Mac, PR8's resident probe measured 4.928-second audio at
0.490/0.430s for subsequent requests and 25.472-second audio at 0.538/0.531s.
First requests were 0.959/0.562s, reported separately. This includes encoded audio
read, local SSH forwarding, API decoding and resident inference. It excludes
physical recording finalization and mobile/Tailscale latency. It supports the
agreed target but does not establish the phone's stop-to-edit performance.

Local audio is discarded after stop/cancel/failure. Drafts and images persist
under protected, backup-excluded storage until discarded or locally sent.
Remote images remain under `~/.chadmux/uploads` until manually removed on the Mac;
keep them while the conversation needs them. See PROJECT.md for limits and
uncertain-send/storage-failure behavior.

The simulator cannot prove hardware file protection, microphone/camera behavior,
phone suspension or real mobile reachability. Do not mark the pilot or epic done
until the physical rows above have real evidence. Leave unresolved outcomes in
Jyra with their exact missing observation.


## Foreground-resume candidate acceptance

Implementation is held off main until this candidate is tested on the iPhone.
Use invented draft text and disposable sessions for the checks; do not attach
private terminal screenshots or recordings to issues.

1. Connect explicitly once after upgrading (old archives do not enable resume).
   Open two sessions, leave distinct unsent drafts/photos, and select the second.
2. Switch apps, return, then repeat with short and longer phone locks. The same
   selected session should reconnect without Connect/sidebar taps. Drafts/photos
   remain, keyboard/selection stay dismissed, and the remote display is current.
3. Terminate Chadmux and explicitly reopen it. The same eligible selected tab and
   workspace should restore. Force quit is not a durable Disconnect instruction.
4. Tap Disconnect, background/reopen, then terminate/reopen. Both must stay
   offline until Connect is tapped. No input, recording or upload may replay.
5. Try Wi-Fi/cellular transitions and Tailscale off/on, and an unavailable Mac.
   Failure must stop within thirty seconds with Retry and retained drafts. Restore
   connectivity and tap Retry. Never reset SSH trust to work around a timeout.
6. Verify scrolling, native Copy/Paste, swipe-down keyboard dismissal, photos,
   dictation and the black/white app icon still work.

With an awake Mac and working Tailscale, measure ten warm returns from active
foreground to validated selected-terminal readiness. Record all ten durations;
nearest-rank p95 is the largest value for ten samples. Target ≤3 seconds. Record
actual outcomes and any target miss before accepting release; simulator timing
is not hardware evidence. Missing sessions or changed host identity must preserve
local work and refuse attachment; exercise those with disposable sessions/keys,
not by destroying personal sessions or replacing the Mac's SSH host key.
