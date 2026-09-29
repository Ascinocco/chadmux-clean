# SSH and terminal foundation

Chadmux uses SwiftTerm 1.15.0 (MIT) for UIKit terminal rendering and Citadel
0.12.1 (MIT) for SSH/SFTP/PTY channels. Versions are exact and transitive versions
are recorded in the checked-in SwiftPM resolution. Both support iOS 17 and
build with Xcode 16.4. Citadel uses SwiftNIO SSH and Swift Crypto. See upstream
licenses in the package checkouts and preserve them with distributed software.

Use the UIKit terminal via `TerminalSurface` rather than parsing ANSI in
SwiftUI. Retain one terminal instance for each open session so state/scrollback
survives view updates. The terminal's resize delegate drives PTY window-change
requests. Adopt actual available screen dimensions and tmux's latest-client
window sizing for the v1 pilot. The two-client test measured a 100x30 desktop
remaining attached while a 42x19 phone joined (window 42x18), rotated to 80x19
(window 80x18), then detached (window restored to 100x29). One row is tmux's
status line. Visual readability still needs the hardware pilot.
Do not change a user's global tmux configuration to achieve phone sizing.

Use generated Ed25519 device keys, stored in iOS Keychain, with public-key export
for installation in the Mac's authorized_keys. Citadel also supports encrypted
OpenSSH key import and password authentication; neither is necessary to bootstrap
v1 if the owner can copy the public key onto the Mac. Never use the upstream
acceptAnything host validator: fingerprint confirmation and stored key pinning
belong to connection setup. The probe uses exact trusted keys and asserts that
a different server key is rejected by the actual host validator (not an unrelated network error).

Use tmux's numeric session IDs rather than session names when attaching. Quote
shell arguments and never construct shell commands from user-composed prompts.
Send composed prompts through the PTY as literal bytes. SFTP handles image files;
a direct-tcpip SSH channel will carry access to the companion server's loopback API.

Citadel 0.12.1 can throw ChannelError.alreadyClosed after consuming normal remote
PTY EOF because it closes the channel again. Treat this as normal only after
successfully exhausting the stream; do not suppress arbitrary connection errors.

## Automated checks

The normal Xcode scheme includes existing XCUITest launch/navigation checks,
key/quoting tests and UIKit terminal decoding across fragmented UTF-8/ANSI input.
A real network integration test is opt-in and runs on the simulator:

```sh
python3 scripts/test-transport.py --simulator SIMULATOR_UUID
```

The script creates temporary Ed25519 host/client keys, a rootless loopback-only
OpenSSH server on a free port, and a private fixture file. It does not read or
modify ~/.ssh or existing tmux sessions. The test proves key authentication,
strict host-key rejection, command execution, PTY allocation/resizing, Unicode
and multiline literal input through a separate tmux server, and detach without
killing the remote session. The tmux test disables personal tmux configuration.
The outer harness owns the exact private tmux socket and kills that server
in its finally block even if XCTest crashes or times out. The temporary sshd
is terminated and key material deleted on exit. A skipped
integration test from the normal scheme is not transport validation.

The connection implementation adds Keychain storage, explicit host verification,
a live PTY and direct SSH forwarding. Session sidebar, media and transcription UI
remain subsequent work. Physical-device verification and
visual readability on desktop/mobile remain integrated-pilot requirements.
