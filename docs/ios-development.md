# Chadmux local iOS development and delivery

Read `../PROJECT.md` first. This is the Chadmux adapter for a shared iOS
development runbook (not included here). That runbook explains pairing, wireless delivery, troubleshooting and agent
capability boundaries. These commands also work from a standalone checkout.
If the shared documentation PR is still open, use its branch version linked in
the delivery PR rather than assuming it is already on main.

## Build inputs

| Input | Chadmux value |
| --- | --- |
| Project / shared scheme | `Chadmux.xcodeproj` / `Chadmux` |
| App product / bundle ID | `Chadmux.app` / `com.ascinocco.chadmux` |
| Deployment target | iOS 17.0 |
| Verified development toolchain | Xcode 16.4; iOS 18.6 Simulator; iPhone 11 pilot |
| Unit / UI targets | `ChadmuxTests` / `ChadmuxUITests` |
| Device/team selection | Discover locally; never commit personal identifiers |

Verify the current checkout, source commit and installed toolchain each time.
The canonical checkout may contain the owner's local signing changes; use a task
worktree rather than switching or resetting it. Use task-specific build paths.
Run the following from the Chadmux worktree. Replace all example identifiers.

## Signed build and physical installation

```sh
xcodebuild -version
xcrun devicectl list devices
CHADMUX_DEVICE='PAIRED_DEVICE_IDENTIFIER'
CHADMUX_TEAM='LOCAL_DEVELOPMENT_TEAM'
CHADMUX_DEVICE_BUILD='/tmp/chadmux-current-task-device'

xcodebuild -project Chadmux.xcodeproj -scheme Chadmux \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$CHADMUX_DEVICE_BUILD" \
  DEVELOPMENT_TEAM="$CHADMUX_TEAM" CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY='Apple Development' -allowProvisioningUpdates build
```

Continue only after a successful build. Install the device product, not a
Simulator product:

```sh
xcrun devicectl device install app --device "$CHADMUX_DEVICE" \
  "$CHADMUX_DEVICE_BUILD/Build/Products/Debug-iphoneos/Chadmux.app"
xcrun devicectl device process launch --device "$CHADMUX_DEVICE" \
  com.ascinocco.chadmux
```

This is the workflow used for the microphone fix and icon candidate. The paired
connection can use USB or the network; no App Store/TestFlight upload is involved.
For a verified wireless run, remove the cable, confirm the paired device is
reachable, then install. Do not infer cable-free delivery from a CoreDevice
“tunnel” message alone. Tailscale is for Chadmux's remote SSH session, not a
requirement or replacement for Xcode pairing.

Install in place to preserve saved connection settings, device SSH key, scoped
transcription token and drafts. Never uninstall or change bundle/team identity
as a casual troubleshooting step. If launch is refused because the phone is
locked, installation may already have succeeded; ask the owner to unlock and open it.
Opening Chadmux restores local state, then resumes the selected previously attached
session when saved connection intent permits. Explicit Disconnect disables resume;
legacy archives require one successful explicit Connect. No terminal message
or dictation should be sent automatically as part of deployment.

## Simulator and XCUITest

```sh
xcrun simctl list devices available
CHADMUX_SIMULATOR='INSTALLED_SIMULATOR_UUID'
CHADMUX_SIM_BUILD='/tmp/chadmux-current-task-simulator'
# Boot only if currently shut down.
xcrun simctl boot "$CHADMUX_SIMULATOR"
xcrun simctl bootstatus "$CHADMUX_SIMULATOR" -b
open -a Simulator

xcodebuild -project Chadmux.xcodeproj -scheme Chadmux \
  -destination "platform=iOS Simulator,id=$CHADMUX_SIMULATOR" \
  -derivedDataPath "$CHADMUX_SIM_BUILD" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES \
  -resultBundlePath /tmp/chadmux-current-task-tests.xcresult test
```

Use a fresh result-bundle path each run. For only voice regressions, add
`-only-testing:ChadmuxTests/VoiceTests` before `test`; UI-only runs use
`-only-testing:ChadmuxUITests`. Ordinary tests skip the opt-in SSH fixture.
For manual synthetic-screen inspection, build with the same arguments and
`build` instead of the test/result-bundle arguments, then:

```sh
xcrun simctl install "$CHADMUX_SIMULATOR" \
  "$CHADMUX_SIM_BUILD/Build/Products/Debug-iphonesimulator/Chadmux.app"
xcrun simctl launch "$CHADMUX_SIMULATOR" com.ascinocco.chadmux
```

Keychain tests require the ad-hoc signing flags shown above. Keep Simulator and
physical DerivedData separate. An existing SwiftPM checkout directory may be
passed via `-clonedSourcePackagesDirPath` to reuse resolved dependencies, but
never share build products across task worktrees or run concurrent package
mutations against the same directory.

Our agent validation used native XCUITest interactions, simulator app lifecycle
commands and test results. Direct agent control depends on the host settings. When T3's device tools are
available, discover with `device_list`, open the selected simulator with
`device_open`, and use the exact agent-device command/config/session returned by
that tool for snapshots, clicks and gestures. Close the interactive device
session before running XCUITest or simctl against that simulator. When those
tools are disabled, XCUITest remains available; do not claim manual interaction.
Use host interactive tools only when actually available and enabled.
Screenshots must use synthetic screens without private terminal contents.

## Real transport and hardware evidence

Run the disposable SSH fixture described in
[SSH terminal foundation](ssh-terminal-foundation.md):

```sh
python3 scripts/test-transport.py --simulator "$CHADMUX_SIMULATOR" \
  --derived-data /tmp/chadmux-current-task-transport
```

It uses isolated SSH keys, loopback sshd and a private tmux socket, not the owner's
personal sessions. The optional `--resident-token-file` mode tests the already
running loopback transcription service using synthetic audio; follow PROJECT.md
and keep the dedicated token file private. Never use the main companion-server token or
print a token into logs. Managed-project work does not authorize service restarts.

Use [the iPhone pilot](iphone-pilot.md) for actual SSH/Tailscale, camera, microphone,
background/relaunch and network-loss checks. The microphone fix was confirmed by
the owner on the physical phone; that does not accept every remaining pilot scenario
or establish a measured two-second mobile latency result. Native codec tests
use invented audio; they are not recordings from the phone microphone.

After a delivery, record the source SHA, build/test outcomes, installation result
and whether launch succeeded. Distinguish tested behavior from user-observed
hardware results. Keep provisioning IDs, tokens, raw logs and screenshots of
private sessions out of tickets and Git. A Git merge or factory pin update alone
does not install a build; a candidate install alone does not mean its PR merged.
