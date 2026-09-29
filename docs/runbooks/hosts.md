# Preparing a host

A host is any machine whose tmux sessions Chadmux attaches to: This Mac, a Linux/NixOS
server or another Linux box. Chadmux installs nothing on a host; everything
below is the host's own configuration.

## Requirements

| Need | Why | Check |
| --- | --- | --- |
| **OpenSSH**, reachable over Tailscale, key-only auth | Chadmux logs in with its per-device key | `nc -z HOST 22`; the banner starts `SSH-2.0-OpenSSH` |
| **Tailscale SSH off** for this host | Tailscale SSH takes over port 22 and ignores per-device keys | Chadmux's **Check SSH** warns if it answers |
| Each device's public key in `~/.ssh/authorized_keys` | Mac app and iPhone have separate keys, so each can be revoked | `~/.ssh` 700, `authorized_keys` 600 |
| An **ed25519 host key** | the one Chadmux pins and is tested with (swift-nio-ssh's built-in host key types are ed25519 and ECDSA) | `ls /etc/ssh/ssh_host_ed25519_key.pub` |
| **An AES-GCM cipher and the `hmac-sha2-256` MAC** (below) | otherwise the handshake stalls before login | `sudo sshd -T \| grep -E '^(kexalgorithms\|ciphers\|macs)'` |
| **tmux** in `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin` or `/bin` | session listing runs tmux with that fixed PATH | `ls -l /usr/local/bin/tmux` |
| **`claude-tmux`** at `~/.claude/scripts/claude-tmux.sh` | + / − / rename run it through your login shell | `test -x ~/.claude/scripts/claude-tmux.sh` |
| `claude` on the **login shell's** PATH | `claude-tmux create` starts it | `$SHELL -lc 'command -v claude'` |
| tmux `set -g mouse on` (recommended) | scrolling with touch/trackpad | `tmux show -g mouse` |

### SSH algorithms

Chadmux uses Citadel's default algorithm set (it never sets
`SSHClientSettings.algorithms`), so it offers only swift-nio-ssh's built-ins:

- key exchange: `curve25519-sha256` (and `@libssh.org`), `ecdh-sha2-nistp256/384/521`;
- ciphers: **`aes256-gcm@openssh.com` and `aes128-gcm@openssh.com` only** (no
  chacha20, no aes-ctr; Citadel's `AES128CTR` is opt-in and not enabled);
- MACs: **exactly `hmac-sha2-256`**. The GCM schemes have no MAC of their own,
  so swift-nio-ssh offers this one name as a placeholder. `hmac-sha2-512` and the
  `-etm` variants are never offered.

The MAC point matters for hardened servers. swift-nio-ssh insists on a MAC match
even when it negotiates AES-GCM, where the MAC is never used. So the server's
`Macs` must include `hmac-sha2-256` specifically; allowing only `hmac-sha2-512` fails
the same way. A server that
allows only `*-etm@openssh.com` MACs (NixOS's hardened default) fails the
handshake right after KEXINIT. The client doesn't close the socket, so sshd just
logs `Timeout before authentication` and the app reports that it couldn't
connect. Fix it on the host by adding `hmac-sha2-256` to `Macs`. With AES-GCM
negotiated it's ignored.

## This Mac

1. System Settings › General › Sharing › **Remote Login**: on, your user only.
2. Add the Mac app's (and the iPhone's) public key to `~/.ssh/authorized_keys`.
3. Install tmux with Homebrew (`/opt/homebrew/bin/tmux`).
4. Install `claude-tmux` from a clone of [github.com/Ascinocco/q-factory-clean](https://github.com/Ascinocco/q-factory-clean): `scripts/install-claude-tmux.sh`.
5. macOS's sshd already offers the needed algorithms.

## A NixOS server (declarative configuration)

On a NixOS server, make these changes in its declarative configuration rather
than by editing the box. It needs:

- each device key (`chadmux-mac`, `chadmux-iphone`, …) authorized for the SSH user;
- `hmac-sha2-256` allowed in sshd's `Macs` for swift-nio-ssh;
- `/usr/local/bin/tmux` linked (for example by tmpfiles), since NixOS keeps tmux
  under `/run/current-system/sw/bin`;
- `claude-tmux` installed at `~/.claude/scripts/claude-tmux.sh`.

If Chadmux's client ever offers `-etm` MACs or a wider tmux PATH, these
host-side workarounds can be reverted. The owner decided not to change the
client for now (local-only software).

To add a new device key on such a server, add it to its configuration and
deploy it. Don't append to `authorized_keys` by hand, because a rebuild would
drop it.

## Another Linux host

Same checklist: OpenSSH with key-only auth, the device keys,
AES-GCM and `hmac-sha2-256` allowed, an ed25519 host key, tmux on the fixed PATH (link it into `/usr/local/bin` if
needed), `claude-tmux` from github.com/Ascinocco/q-factory-clean, and `claude` on the login shell's PATH.
The Linux container in the test suite (Fedora, bash login shell) covers the
tmux/SFTP/`claude-tmux` behaviour. See [testing.md](testing.md).

## Verifying a host by hand

From the Mac, without Chadmux:

```sh
nc -z HOST 22 && echo port-open
ssh -o Ciphers=aes256-ctr -o MACs=hmac-sha2-256 HOST true && echo mac-ok
ssh HOST 'PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin tmux -V'
ssh HOST 'test -x ~/.claude/scripts/claude-tmux.sh && $SHELL -lc "command -v claude"'
```

The `mac-ok` check forces a non-AEAD cipher. OpenSSH skips MAC negotiation
for AES-GCM, so pairing the MAC with GCM would pass even on a server that
Chadmux can't reach. With aes-ctr, it succeeds only if the server's `Macs` list
includes `hmac-sha2-256`, which is the condition Chadmux needs. It can fail
falsely on a server that permits no aes-ctr cipher at all, where Chadmux could
still connect. In that case, read the server's lists directly with
`sudo sshd -T | grep -E '^(ciphers|macs)'` and look for an `aes*-gcm@openssh.com`
cipher and `hmac-sha2-256`.

To watch a connection attempt on a Linux host: `ssh USER@HOST journalctl -u sshd -f`
(no sudo needed on many systems). A healthy Chadmux login shows `Accepted publickey … ED25519`
with the device key's fingerprint.
