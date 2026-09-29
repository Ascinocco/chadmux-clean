# Testing Chadmux

Four layers, from fastest to slowest. Each one tells you something the others
can't, so know which one a change needs ([validation.md](validation.md)).

| Layer | Scheme / target | Needs | Proves |
| --- | --- | --- | --- |
| Unit | `Chadmux` › `ChadmuxTests`, `ChadmuxMac` › `ChadmuxMacTests` | a simulator, or the Mac with a signing team | logic, Keychain, storage, parsing, byte-exact paste framing |
| iOS UI | `Chadmux` › `ChadmuxUITests` | a simulator | screens, navigation, relaunch; the `*AgainstLiveTmux` tests need a fixture |
| Mac UI | `ChadmuxMacUI` › `ChadmuxMacUITests` | the real desktop and Accessibility permission for the runner | the window, sidebar, shortcuts, no input bar, image paste |
| Real SSH | `SSHIntegrationTests` (+ Mac drop test) via `scripts/test-transport.py` | a disposable sshd (and Docker for `--linux`) | real SSH, PTY, tmux, SFTP, `claude-tmux`, resume, changed keys |

Default runs **skip** the fixture-backed tests. A skip is not a pass: read the
summary line and check the skip count for tests you meant to run.

## Common setup

```sh
TASK=$(basename "$PWD")                           # one set of paths per task worktree
DD=/tmp/chadmux-$TASK                             # DerivedData, deleted afterwards
PKG=/tmp/chadmux-v1-build/SourcePackages          # optional shared SwiftPM checkout
export CHADMUX_DEVELOPMENT_TEAM=YOUR_TEAM         # Mac runs only; never committed
SCRATCH=$(mktemp -d)                              # notes and result bundles for this task
```

Pass `-clonedSourcePackagesDirPath "$PKG"` (xcodebuild) or `--packages "$PKG"`
(test-transport) to avoid re-downloading dependencies. Never share DerivedData
between worktrees, because stale test bundles get reused.

### Simulators: always test two sizes

Create task-owned simulators, record their ids and delete them afterwards:

```sh
RT=com.apple.CoreSimulator.SimRuntime.iOS-18-6
SE=$(xcrun simctl create "cc-$TASK-SE" "iPhone SE (3rd generation)" $RT)
MAX=$(xcrun simctl create "cc-$TASK-MAX" "iPhone 16 Pro Max" $RT)
echo "SE=$SE MAX=$MAX" > "$SCRATCH/sims.txt"      # so cleanup survives a lost session
# … tests …
xcrun simctl shutdown $SE $MAX; xcrun simctl delete $SE $MAX
```

SE is the small screen (keyboard and sidebar crowding), and Pro Max is the large
one. Both must pass for any change that iOS compiles.

## Unit and UI tests

```sh
# iOS: unit + UI (fixture tests skip)
xcodebuild -project Chadmux.xcodeproj -scheme Chadmux \
  -destination "platform=iOS Simulator,id=$SE" -derivedDataPath "$DD" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES test

# Mac: unit (+ real SSH tests that skip without a fixture)
xcodebuild -project Chadmux.xcodeproj -scheme ChadmuxMac \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DD" \
  DEVELOPMENT_TEAM=$CHADMUX_DEVELOPMENT_TEAM CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates test

# Mac UI, offline tests (no fixture): drives the real desktop
xcodebuild -project Chadmux.xcodeproj -scheme ChadmuxMacUI \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DD" \
  DEVELOPMENT_TEAM=$CHADMUX_DEVELOPMENT_TEAM CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates test
```

- Simulator tests must be ad-hoc signed (`CODE_SIGN_IDENTITY=-`): Keychain
  doesn't work unsigned.
- Narrow a run with `-only-testing:ChadmuxTests/VoiceTests` and similar.
- **Mac UI tests take over the keyboard and mouse.** Warn the owner before starting
  them, and don't run two at once. The first run asks for the test runner to be
  allowed under System Settings › Privacy & Security › Accessibility. Under
  `--ui-testing` the app reads pasted images from a private pasteboard and never
  touches the real clipboard.

## Real SSH: `scripts/test-transport.py`

The harness starts a **disposable** loopback sshd with generated keys, a private
tmux socket, a fake `claude` and a fixture transcription API. It passes their
details to the tests through `CHADMUX_TRANSPORT_FIXTURE` and tears everything
down afterwards, even when a test crashes. It never reads `~/.ssh` or touches
personal sessions.

| Command | Runs |
| --- | --- |
| `test-transport.py --simulator $SE` | the full iOS `SSHIntegrationTests` |
| `… --simulator $SE --linux` | the Linux-applicable integration tests against a Fedora container (Docker must be running) |
| `… --simulator $SE --multi-ui` | iOS multi-host sidebar UI test (two hosts plus an offline one); add `--linux` to make "Arch" the container |
| `… --simulator $SE --manage-ui` | iOS create/end/rename UI test against live tmux |
| `… --simulator $SE --resume-ui` | foreground and cold resume UI test |
| `… --simulator $SE --native-ui` | swipe, native Copy and Paste, live-return UI test |
| `test-transport.py --mac` | the Mac `SSHIntegrationTests` (includes the terminal drop test) |
| `… --mac --linux` | Mac integration tests against the container, plus the drop test |
| `… --mac --multi-ui` | Mac window test: grouped hosts, same name on two hosts, Cmd-T/W/R/1…8; add `--linux` to make "Arch" the container |
| `… --mac --manage-ui` | Mac create/end plus an image ⌘V uploaded and pasted into a live session; Mac dictation (injected recorder/transcriber) pasted with no Enter, Esc/× paste nothing, Live beside the mic |

Useful flags:
- `--derived-data "$DD"` and `--packages "$PKG"`;
- `--only-testing ChadmuxTests/SSHIntegrationTests/testName` to run one test;
- `--claude-tmux PATH` for the script under test (default:
  `~/.claude/scripts/claude-tmux.sh`; tests that need it skip without it);
- `--result-bundle PATH` for evidence (a fresh path each run);
- `--resident-token-file FILE` is an opt-in probe of a running transcription
  service using synthetic speech. The file holds only the scoped token (mode
  600) and is never printed. Since the cutover there is no Mac API to probe.

`--linux` builds `scripts/linux-fixture` (Fedora, OpenSSH, tmux 3.7, bash login
shell, native arm64) and removes the container afterwards. It is not Arch or
NixOS. Real-host specifics belong to the hands-on pilot on a real server.

## Manual checks against a private tmux

When you need to see what Claude does with pasted bytes (for example, checking
that a pasted path becomes `[Image #N]`), use a private server, never the owner's:

```sh
T=$(mktemp -d); mkdir -m 700 -p "$T/tmux-$(id -u)"; S="$T/tmux-$(id -u)/probe"
env -u TMUX tmux -S "$S" new-session -d -s probe -x 120 -y 40
env -u TMUX tmux -S "$S" send-keys -t probe 'claude' Enter
# … drive it with send-keys / paste-buffer, read with capture-pane -p …
env -u TMUX tmux -S "$S" kill-server; rm -rf "$T"
```

Accepting Claude's trust prompt marks that folder as trusted, so use a scratch
folder, not a real project.

## Cleanup (every time)

```sh
rm -rf "$DD" /tmp/chadmux-transport-build            # DerivedData
rm -rf /tmp/*.xcresult "$SCRATCH"/*.xcresult          # result bundles (Mac UI ones record the screen)
xcrun simctl delete $SE $MAX                          # task simulators
docker image ls | grep chadmux                        # Linux fixture image, remove if unneeded
df -h /                                               # report free space
```

Confirm the owner's tmux is untouched: `tmux ls` from a normal terminal should list the
same sessions as before.
