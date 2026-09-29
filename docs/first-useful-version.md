# Chadmux: first useful version

Status: product specification from the owner's design discussion, 2026-09-22.
This document defines acceptance; see PROJECT.md for the delivered implementation.

## Outcome

Use Claude Code on the go from an iPhone, connected over SSH through Tailscale
to the owner's MacBook. Claude and its projects remain on the Mac. Chadmux presents
the real terminal with a comfortable message composer supporting typed text,
editable dictation and multiple photos. Desktop and mobile attach to the same
running tmux sessions.

## A real session

1. Open the saved Mac connection and select an existing tmux session.
2. Read the live Claude terminal and navigate any interactive prompts.
3. Type a draft, or tap the microphone, speak, and tap again to stop.
4. Wait for transcription, then manually edit the text in the composer.
5. Take photos or select photos/screenshots from the library. Inspect their
   thumbnails and remove any unwanted attachment.
6. Tap Send. Required image uploads finish before Chadmux submits the text and
   remote image references to the selected terminal.
7. Switch to another session using the left sidebar. Each retains its own draft
   and attachments. Return to the same session at the desktop.

## Agreed requirements

### Connection and shared sessions

- Initial target: iPhone and one MacBook with Tailscale configured externally,
  macOS SSH access enabled, and Claude already running in tmux.
- List the Mac's tmux sessions through SSH and attach to the selected session.
  Use the existing tmux server and user; do not create a separate session registry.
- Each open Chadmux tab refers to a tmux session. Desktop and mobile can attach
  to the same session. Closing a tab detaches its client, not kills the session.
- The Mac must remain awake and reachable. Disconnection is presented honestly.
- tmux sessions and saved Claude conversation histories are different things;
  v1 does not aggregate historical conversations or integrate Claude Desktop.

### Screen and navigation

- Use cmux as the interaction reference: vertical session tabs in a collapsible
  left sidebar, selected session highlighted, and a persistent top-left toggle.
- Default to collapsed in iPhone portrait; collapsing frees the terminal and
  composer width. Exact dimensions and expanded layout need a phone prototype.
- Show the actual terminal output, not reconstructed chat bubbles.
- Keep Escape, Tab, arrow keys, Enter and Ctrl-C accessible in a control row
  above the composer, including when the software keyboard is closed.
- Composer Send submits a composed message; terminal Enter sends a terminal
  control key. Make the distinction visible and verify it in interactive prompts.
- Support keyboard-open/closed layouts, safe areas and accessible control labels.

### Text and sending

- Keep an editable multiline draft per open session. Switching tabs preserves it.
- Typed and dictated text can be combined. Dictation never submits automatically.
- Bind a send operation and its attachments to the originating session even if
  the user switches tabs while uploads are running.
- Submit composed text as literal terminal input, not interpolated shell code.
  Validate multiline input and Claude's actual terminal paste behavior.
- Disable duplicate Send actions during an in-flight submission. Preserve the
  draft on failure; distinguish successful local transmission from Claude receipt.

### Photos

- Support camera capture and system photo-library selection, including screenshots.
- Allow multiple attachments, with preview thumbnails and individual removal.
- Transfer images over the existing SSH connection (for example SFTP) into a
  dedicated remote upload directory with unique, safely handled filenames.
- Submit remote image paths with the text; confirm Claude can read every uploaded
  image. Do not depend on desktop clipboard image-paste support over SSH.
- If any required upload fails, do not submit a partial message silently. Keep
  the draft/attachments available for retry or removal.
- Handle permission denial, cancellation and interrupted transfer visibly.

### Dictation

- Tap microphone to start; tap again to stop and request transcription. Show
  recording, transcribing, failure and ready states; allow cancellation.
- The companion server API accepts the recording and returns JSON text to the composer.
- A persistent whisper.cpp server on the Mac keeps its selected model loaded.
  Never spawn whisper-cli and reload the model for every recording.
- The companion server remains the client-facing API; Whisper is an internal loopback service.
  Chadmux accesses the server through SSH forwarding; do not expose the API or
  Whisper broadly on the tailnet. Document this deliberate mobile-access change
  to the server's previous local-only architecture during implementation.
- Preserve existing text. Capture the originating tab and intended insertion
  location; if the draft changes during transcription, merge without overwriting
  edits or offer explicit insertion. Never insert into a newly selected tab.
- Start with Whisper output directly. No Claude CLI cleanup, live transcription,
  automatic submission or spoken replies in v1.
- Warm responsiveness target confirmed by the owner: editable text within two seconds
  after stopping a typical recording up to 30 seconds, on the awake Mac with its
  model already loaded. Validate actual mobile latency during the phone pilot.
- Model/version, audio limits and latency target must be selected from a short
  measured spike on the target Mac, not guessed. Assess coding vocabulary,
  silence/no-speech, ordinary room noise and short/long prompts.

### Recovery

- Preserve drafts and attachments through temporary connection loss and session
  switching. Restore unsent drafts across app relaunch as required by the
  recovery ticket; document retention and cleanup behavior before shipping.
- Reconnect to the same tmux session when it still exists. Missing sessions,
  sleeping hosts and failed authentication have clear recovery paths.
- Never automatically replay a submission whose delivery is uncertain. Ask the
  user to inspect the terminal and choose whether to retry.
- A phone connection is not expected to stay alive while iOS suspends the app;
  the remote tmux session continues independently while the host is running.

## Implementation boundaries and proposed defaults

These are engineering proposals to validate, not additional user decisions:

- Prefer SSH key authentication with private material in iOS Keychain and
  explicit host-key verification, including refusal on an unexpected change.
- Reuse a maintained iOS SSH/terminal library after checking licensing, terminal
  compatibility and packaging. Do not implement a terminal parser from scratch.
- Default to one active recording; switching sessions must not move its result.
- Bound upload sizes, recording duration and concurrent transcription. Return
  actionable unavailable/busy/invalid-audio errors without logging content.
- Use temporary audio files and clean them on success/failure/cancellation.
  Define remote photo retention so images remain available to the conversation
  without accumulating forever or being deleted while Claude still needs them.
- Keep app credentials, recordings, photos, prompts and terminal contents out of
  commits, analytics, service logs and test artifacts. Use synthetic fixtures.
- Do not couple SSH/terminal access to transcription availability. The app still
  works when the companion server or Whisper is unavailable; dictation reports the failure.

## Explicitly outside this release

App Store distribution, multi-user hosting, Tailscale account provisioning,
a desktop app, split-pane management, browser panes, agent notifications,
remote session creation UI, Claude history synchronization, live dictation,
text-to-speech and automatic Claude transcript rewriting. The initial sidebar
attaches to sessions that already exist; remote session creation can follow.

## Delivery and acceptance

The owner selected local Xcode builds and direct iPhone testing first. Prove the core
workflow on their phone before setting up TestFlight build/distribution automation.
TestFlight is a later milestone; no enrollment, signing-account changes or upload
pipeline is part of the initial pilot. The app is native Swift with SwiftUI.

Use separate Chadmux and companion-server PRs. Follow the factory's seven-lens review and
response loop, including comparison with this spec. For this initial run only,
the owner explicitly authorized fresh-eyes Codex subagent seven-lens reviews plus
coordinator verification while Claude capacity is unavailable. Identify this
substitution honestly in review records; do not use an Opus/Sonnet identity stamp
or change the factory's default protocol. Never record a review that did not run.

The epic is accepted only after an integrated iPhone-to-Mac pilot demonstrates:

- Two disposable tmux sessions discoverable from mobile and desktop, with
  attach/switch/detach behavior and readable terminal resizing.
- A multiline typed prompt and terminal permission/choice navigation.
- Two or more photos, one removed/replaced, then a message Claude can interpret
  using all retained images.
- Record/stop/transcribe, manual correction and explicit Send, including existing
  draft text and a tab switch during transcription.
- Repeated requests served by the same resident Whisper model, with cold-start
  distinguished from warm latency and evidence against the agreed target.
- Connection loss during upload, an ambiguous send, app background/foreground,
  and reconnect without losing drafts or duplicating a submission.
- Unavailable Whisper does not prevent typing or normal SSH use.

Run appropriate Swift tests/simulator checks and companion-server endpoint/integration
checks. Hardware testing is necessary for camera, microphone, Tailscale and iOS
suspension; simulator success alone is not acceptance. Device signing/setup is
an execution prerequisite, not a reason to claim hardware validation early.

## Decisions still to validate

No further product answers block specification or ticket creation. Before
implementation commits to them, resolve the SSH/terminal libraries, shared
terminal sizing, Whisper model/latency, exact upload/recording limits and media
retention. Bring meaningful UX tradeoffs back to the owner; routine engineering
choices belong in their implementation tickets.

## References

- [cmux sidebar interaction](https://github.com/manaflow-ai/cmux)
- [tmux sessions](https://github.com/tmux/tmux/wiki/Getting-Started)
- [whisper.cpp](https://github.com/ggml-org/whisper.cpp)
- [Persistent Whisper server](https://github.com/ggml-org/whisper.cpp/tree/master/examples/server)
- [Claude image paths](https://code.claude.com/docs/en/common-workflows#work-with-images)

## Delivery map

The work is tracked as tickets on the Chadmux board. The transcription backend
belongs to the companion server's board and is linked as a dependency.

| Work |
| --- |
| Chadmux v1: mobile Claude sessions with text, photos and dictation |
| Validate iOS SSH and terminal integration choices |
| Connect to the Mac over SSH through Tailscale |
| Add shared tmux sessions and collapsible vertical sidebar |
| Build editable composer and always-visible terminal controls |
| Capture, select and send multiple photos to remote Claude |
| Provide resident whisper.cpp transcription for Chadmux |
| Add tap-to-record dictation with editable transcript |
| Preserve drafts and recover SSH sessions without duplicate sends |
| Validate the complete Chadmux v1 on iPhone and Mac |
