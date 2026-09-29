# Disposable Linux SSH/tmux host for Chadmux's opt-in integration tests.
# test-transport.py --linux builds and runs it; nothing here is used by the app.
#
# Fedora, native on Apple silicon: Arch's official image is x86-only, and under
# Docker's x86 emulation OpenSSH's seccomp sandbox cannot start (prctl EINVAL).
# The real Arch host is covered by the iPhone pilot.
FROM fedora:latest
RUN dnf install -y --setopt=install_weak_deps=False openssh-server tmux python3 glibc-langpack-en \
    && dnf clean all
# The fixture directory is bind-mounted at its macOS path, so the SSH user has the
# same name and uid as the Mac user running the tests. Login shell: bash, as on Arch.
ARG FIXTURE_USER
ARG FIXTURE_UID
# "*" (no usable password) rather than useradd's locked "!!": without PAM, sshd
# refuses locked accounts even for key authentication.
RUN useradd --create-home --uid "$FIXTURE_UID" --shell /bin/bash "$FIXTURE_USER" && usermod -p '*' "$FIXTURE_USER"
EXPOSE 22
