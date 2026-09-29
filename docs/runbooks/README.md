# Chadmux runbooks

These pages cover how to run, test and validate Chadmux. They are procedures;
[PROJECT.md](../../PROJECT.md) remains the source for architecture and behaviour
contracts, and the older docs in `docs/` hold specifications and pilot records.

| I want to… | Read |
| --- | --- |
| Use Chadmux on the iPhone, install a new build on it, or recover it | [iphone.md](iphone.md) |
| Use Chadmux on the Mac, install/update/roll back the Mac app | [mac.md](mac.md) |
| Prepare a machine (macOS or Linux/NixOS) so Chadmux can use it as a host | [hosts.md](hosts.md) |
| Run the automated suites: unit, UI, real SSH, Linux container | [testing.md](testing.md) |
| Decide what a change needs before a PR, and prove there is no regression | [validation.md](validation.md) |
| Fix something that isn't working | [troubleshooting.md](troubleshooting.md) |

## The system in one paragraph

Chadmux is a native SwiftUI client, for iPhone (`Chadmux` scheme) and macOS
(`ChadmuxMac` scheme), for **tmux sessions over SSH**. It never runs Claude or
tmux itself: each host (This Mac, a Linux server, …) runs OpenSSH, tmux and the
`claude-tmux` script, and Chadmux attaches to that host's tmux sessions through
a real PTY (Citadel/swift-nio-ssh for SSH, SwiftTerm for the terminal). Every
device has its own Ed25519 key in its Keychain, and every host key is pinned on
first use. The iPhone has a message composer (text, photos, dictation); the Mac
has no input bar, and you type straight into the terminal, drop images on it and
dictate into it with the mic in its corner.

## Rules that apply to every runbook

- **Never touch the owner's real tmux server in tests.** Always `tmux -S <private socket>`
  and `env -u TMUX` for scripts. `$TMUX` overrides `TMUX_TMPDIR`, so a bare
  `tmux kill-server` inside a tmux pane kills the real server. It has happened.
- **Never commit** signing teams, device identifiers, hostnames/addresses beyond
  the documented placeholders, keys, tokens, or screenshots of real sessions.
  Pass the team on the command line (`CHADMUX_DEVELOPMENT_TEAM=…`).
- **Never reset host-key trust to get past an error** without independently
  verifying the host's new key on the host itself.
- **Clean up after native builds.** The development Mac is short of disk space:
  one DerivedData folder per task under `/tmp`, deleted afterwards; simulators you
  created are deleted afterwards; `.xcresult` bundles from Mac UI runs contain a
  recording of the whole screen, so delete them without opening them.
- **Screenshots and fixtures use invented content only.**
