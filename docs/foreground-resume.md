# Resume the Chadmux workspace on foreground return

Status: implementation candidate; physical-device acceptance and implementation merge pending.
Research date: 2026-09-23. Code baseline: Chadmux `e8c6cc5` (main after PR16).
Tracked as a single epic on the project's work board.

## Outcome and boundary

After locking the phone or switching apps, reopen Chadmux and return to the same
selected tmux session with the same tabs and unsent work, without tapping Connect
and selecting the session again. Also support an explicit cold reopen after iOS
removed the process from memory. Keep the current background cleanup and use the
existing Mac, Tailscale, SSH, Keychain and tmux architecture.

“Where I left off” means the same session identity and local workspace, showing
the remote application's current display, including any existing tmux copy mode.
“Live” here means a validated connection, not permission to cancel copy mode or
change shared remote state. Claude can continue working while
the phone is away. Do not restore stale terminal pixels, exact scroll offsets,
text-selection handles, copy-mode position, keyboard focus, or a previously active
remote window/pane if the desktop has since changed it. Do not save terminal
contents. Resume does not submit, restart Claude, create a replacement tmux
session, wake the Mac, start Tailscale, or restart companion-server services.

This is foreground restoration, not an always-connected background SSH feature.
No audio/location background mode, keepalive service, push backend, Mosh migration,
background scheduler, new API endpoint, or relaxed device protection is required.

## Research and existing implementation

- iOS ordinarily suspends background apps; general-purpose continuous background
  execution is unavailable. A bounded background task is for finishing work,
  not a persistent SSH guarantee. [Apple background execution limits](https://developer.apple.com/forums/thread/685525).
- SwiftUI distinguishes active (interactive), inactive and background scenes.
  Respond to real foreground transitions, not every transient inactive event.
  [Apple ScenePhase.active](https://developer.apple.com/documentation/swiftui/scenephase/active).
- Keychain accessibility is conditional on device state. Keep the app's current
  `WhenUnlockedThisDeviceOnly` policy and complete file protection; defer reads
  and resume until protected data is available. [Apple keychain accessibility](https://developer.apple.com/documentation/security/restricting-keychain-item-accessibility).
- Network reachability checks cannot prove a host is reachable. Attempt the
  actual connection and handle its result. Citadel/NIO SSH is not URLSession;
  URLSession's waiting behavior is not an implementation shortcut here. A path
  monitor is unnecessary for the first iteration. [Apple reachability guidance](https://developer.apple.com/documentation/systemconfiguration/scnetworkreachability-g7d).
- tmux supports detached sessions and reattachment. Reuse existing sessions,
  without starting duplicate Claude processes. [tmux getting started](https://github.com/tmux/tmux/wiki/Getting-Started).

Code findings, not platform guarantees:

| Area | Current behavior | Required change |
| --- | --- | --- |
| `ContentView.swift` | Background calls `workspace.background()`; no active resume hook | Central foreground/unlock lifecycle routing |
| `TmuxSessions.swift` | Background cancels media/submission work, checkpoints, disconnects; Connect refreshes sessions but does not attach selected tab | Separate user intent from transport teardown; one resume coordinator |
| `MacTransport.swift` | Control SSH and per-tab SSH; generation guard; pinned keys; exact tmux client/instance validation; fifteen-second connect and attach limits | Awaitable, typed completion/failure usable by coordinator, cancellation and whole-operation deadline |
| `DraftRecovery.swift` | Version-one protected archive stores selected tab, ordered tabs, drafts, photos, pending transcripts and uncertainty; restore is offline | Compatible resume metadata and explicit migration/defaults |
| `ConnectionStore.swift` | Device-only unlocked Keychain; profile-specific trust | Preserve protections and explicit trust decisions |
| Tests | Offline relaunch and manual reconnect are intentional assertions today | Keep offline construction, then explicitly test active-triggered resume |

The existing v1 recovery ticket (preserve drafts and recover SSH sessions) remains its own
acceptance record. This epic adds automatic foreground behavior; it does not
retroactively mark that ticket or the v1 hardware pilot complete. The companion server's
transcription backend requires no change.

## Behavioral contracts

### C1 — Durable workspace and upgrade compatibility

Retain exact draft text, attachment order/identities, pending edited transcripts,
uncertain-send acknowledgement state, tab order, selected tab and sidebar state.
Scope all metadata to the exact Mac profile. Store eligible session identities,
not just display names or reusable numeric IDs. Reuse the existing session ID plus
server PID/session-created instance verification at discovery and attachment.

Extend the versioned recovery model compatibly: read existing version-one files,
default absent resume metadata to disabled, and preserve their contents. Do not
silently enable networking for a legacy archive; an explicit successful Connect
on the new build establishes resume intent. Add a migration fixture and enforce
the existing archive limits and protected atomic writes. Unknown/corrupt versions
must remain intact and visibly unavailable, not become an empty workspace.

### C2 — Connection intent and deliberate disconnection

Desired connection is different from actual socket state. Successful explicit
Connect establishes intent for that profile; only successfully validated tab
attachments become eligible for automatic reattachment. Background disconnect,
transient network loss and Mac sleep do not erase intent. Closed tabs are removed
from eligibility; profile changes invalidate the old resume operation and intent.

Disconnect clears intent, cancels outstanding work and closes phone clients.
Persist the opt-out even if saving the draft archive fails, so reopening cannot
undo the user's Disconnect. A small profile-scoped suppression preference is
acceptable; it contains no credentials or terminal data. Enabling cold resume
requires a successful recovery checkpoint. Test failed saves explicitly.

If no tabs were attached, an eligible foreground return can restore the control
connection/session list without opening a shell or choosing a session for the user.
A restored offline tab alone is never proof of connection intent.

### C3 — Lifecycle triggers

| Event | Result |
| --- | --- |
| Active to inactive only (system UI/interruption) | Do not disconnect or start another resume cycle; retain existing microphone interruption rules |
| Background or lock | Save resumable intent/workspace, cancel media/import/submission operations, stop gestures, close phone SSH clients; tmux persists |
| Background to active, data available | Start one eligible foreground resume cycle |
| Explicit cold launch to active | Restore local data first; resume only if compatible persisted intent permits |
| Active but protected data unavailable | Show unlock/recovery state; do not read secrets, overwrite archives or delete media; start once active and data becomes available |
| Repeated active/unlock notifications | Coalesce; never start duplicate cycles or reset exhausted retry budget |
| Connection lost while already active | Show disconnected/Retry; retain intent for the next actual foreground cycle; no new automatic retry loop in this iteration |
| Explicit force quit | No work while closed; on the next user launch apply the same persisted-intent rule as any cold reopen |

iOS does not provide a dependable application-level distinction between every
kind of process termination. Force-quit is not the same as Chadmux's explicit
Disconnect; this distinction must be documented in the pilot instructions.

### C4 — No automatic side effects

Reattachment may issue bounded SSH/tmux discovery and attach commands. It must
never replay draft text, terminal keys, uncertain messages, uploads or recordings.
Backgrounded dictation/import/upload work remains cancelled. Retain draft/photos
and pending transcript for explicit user action. Any submission that may have
been written retains the existing uncertain-delivery warning and acknowledgement
requirement. Reconnecting does not count as acknowledgement.

### C5 — One bounded resume coordinator

Own the process in `SessionWorkspace` on the main actor; do not launch independent
reconnect loops from views, each tab, network monitors and transport callbacks.
Sequence: eligibility check → trusted control SSH → bounded session discovery →
identity validation → attach current selected eligible tab → validated live state.
Use transport completion/events, not polling presentation strings.

At most two sequential attempts per foreground cycle: one immediately, one after
two seconds only for classified transient network/timeout failure. The complete
cycle has a thirty-second wall-clock deadline including delays, discovery and
attachment. Stage timeouts must fit inside remaining time. Cancel and close any
partially opened resources at expiry; a late success is not allowed to reconnect.
Manual Retry starts a fresh bounded cycle. No indefinite retry or background timer.

Unknown/changed host key, authentication failure, invalid profile and missing or
replaced session do not auto-retry. Show the appropriate existing recovery action.
Unknown host requires explicit verification; changed keys are never silently
trusted. Do not weaken pinning or automatically overwrite a pin to make resume work.

Every cycle carries a generation/profile identity. Background, Disconnect, profile
change or superseding user intent cancels it; all completions validate ownership.
Keep at most one control connection and one connection per attached tab. Eliminate
the current view-level refresh callback race by assigning discovery to a single
owner; manual Connect must use the same sequencing contract.

### C6 — Selected tab first, others on demand

Restore the previous selected tab before attaching anything else. Other previously
connected tabs stay visible with their drafts and attach lazily when selected.
This limits reconnect work to the screen the user needs rather than opening up to
eight SSH streams on every return. Selecting a tab during resume supersedes the
old target without consuming a new global retry budget. A late result may not
switch selection or send input to an old target.

A missing/replaced session keeps its offline tab and draft, with “Session no longer
exists” or equivalent and Close/Refresh actions. Never silently attach to a new
session with the same name/ID, choose a different session, or recreate Claude.
A rename with the same validated instance is allowed; refresh the display label
without changing ownership or drafts.

### C7 — Honest UI and input gating

Restore local draft content immediately when readable, so it remains editable
while connecting. Show a compact “Reconnecting…”/“Attaching…” state in existing
connection UI; no new modal workflow for ordinary resume. “Connected” for the
selected terminal requires the existing exact tmux-client attachment validation,
not merely a successful control SSH connection. Session discovery success is not
terminal readiness. Gate terminal input and Send until the selected transport is
ready; keep existing bracketed-paste and uncertain-send checks.

On failure keep the workspace visible with a reason and explicit Retry/Disconnect.
If verification is required, use existing host-verification UX. Do not claim the
Mac is asleep from a generic timeout; suggest checking Mac/Tailscale connectivity.

### C8 — Return experience

Show current live server output, selected session and unsent draft without extra
Connect/sidebar taps. Keyboard and transient text selections remain dismissed;
tap the input to continue typing. Preserve scrolling and native Copy/Paste, swipe-
down keyboard dismissal, photos, dictation and icon. Resume must not alter the
user's tmux sizing policy or desktop window/pane selection. Do not clear unrelated
terminals, create new tabs, or automatically reopen a manually closed tab.

### C9 — Acceptance evidence

Use injected lifecycle/time boundaries and existing disposable SSH/tmux fixtures
for deterministic cancellation/deadline tests. UI tests must drive actual
background/foreground and explicit relaunch; a constructor test alone is not a
resume test. Test both warm in-memory return and reconstructed workspace behavior.

| Scenario | Observable pass condition |
| --- | --- |
| Short/long lock, app switch | Same selected session becomes validated live; no Connect/selection taps |
| Cold reopen after process termination | Saved eligible session and unsent work restored; no automatic sends |
| Two sessions / rapid tab selection / eight saved tabs | Correct selected target, only needed attachment, no stale completion changes focus |
| Deliberate Disconnect then reopen | Stays offline across warm and cold return |
| Missing/replaced session or changed host key | Refuses wrong attachment/trust; preserves local work |
| Tailscale unavailable, network transition, sleeping Mac | Bounded attempts and actionable failure; Retry succeeds when service returns |
| Background during connect/list/attach | No lingering connection, duplicate client or late connected UI |
| Upload/dictation/send interrupted | Media stops, retained drafts/photos, uncertain delivery preserved; zero replay |
| Protected data unavailable / save failure / old archive | No data loss, cleanup or credential downgrade; conservative resume policy |
| Existing UI gestures | Scrolling, native Copy/Paste and keyboard dismissal continue to pass |

For actual iPhone pilot use synthetic content and record safe outcomes. Measure
foreground-active to validated-live for ten warm returns with awake Mac and working
Tailscale: target p95 ≤ three seconds (nearest-rank method). Report actual timings;
this is a product target, not a connection timeout. If missed, obtain an explicit
disposition before claiming acceptance. Also test Wi-Fi/cellular changes, Tailscale
recovery and longer locks on hardware; simulator timing cannot substitute.

## Work breakdown and completion

All tickets are on the Chadmux board under the epic above. Implementation was
subsequently authorized; the specification is merged in PR17. The runtime candidate
must remain unmerged until physical-device testing is accepted.

| Order | Ticket | Depends on |
| --- | --- | --- |
| 1 | persisted intent and recovery migration | None |
| 2 | bounded foreground reconnect coordinator | 1 |
| 3 | selected workspace and resume UI | 1, 2 |
| 4 | race/failure/no-replay integration suite | 1–3 |
| 5 | physical pilot and release integration | 4 |

Each implementation ticket includes its own focused tests and exact-head factory
review; ticket 4 adds composed failure scenarios, not a deferral of all testing.
Update the older manual-only wording in PROJECT.md, the pilot/delivery docs and
recovery tests when the behavior changes. Keep legacy archive behavior explicit.
After hardware acceptance, finish reviewed implementation merges and a separate
reviewed factory pin update with clean remote-clone proof. Link evidence back to
this epic. Child status alone does not prove integrated acceptance.
