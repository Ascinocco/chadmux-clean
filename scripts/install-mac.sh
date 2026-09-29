#!/usr/bin/env bash
# Build, install, update or roll back the Chadmux Mac app (a local signed
# Release build in /Applications). See docs/mac-install.md.
#
#   CHADMUX_DEVELOPMENT_TEAM=YOURTEAM scripts/install-mac.sh     install or update
#   scripts/install-mac.sh --rollback                            back to the previous copy
#
# The bundle id and signing team never change between installs, so the
# Keychain items (device key, host trust, tokens), preferences and drafts
# carry over. Nothing is notarized or distributed.
set -euo pipefail

APPS="${CHADMUX_APPLICATIONS_DIR:-/Applications}"          # overridable for tests only
STATE="${CHADMUX_INSTALL_STATE_DIR:-$HOME/Library/Application Support/Chadmux/install}"
BUNDLE_ID="com.ascinocco.chadmux.mac"
APP="$APPS/Chadmux.app"
PREVIOUS="$STATE/previous/Chadmux.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

log() { printf '%s\n' "$*"; }
fail() { printf 'install-mac: %s\n' "$*" >&2; exit 1; }

quit_running() {
  # Quit politely so drafts are checkpointed; tabs and tmux sessions survive.
  [ -n "${CHADMUX_PREBUILT_APP:-}" ] && return 0   # test runs never touch the real app
  if pgrep -f "$APP/Contents/MacOS/Chadmux" >/dev/null 2>&1; then
    log "Quitting the running Chadmux…"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 40); do pgrep -f "$APP/Contents/MacOS/Chadmux" >/dev/null 2>&1 || return 0; sleep 0.25; done
    fail "Chadmux did not quit; close it and run again"
  fi
}

register() {
  [ -x "$LSREGISTER" ] && [ -z "${CHADMUX_PREBUILT_APP:-}" ] && "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
}

# Replace $APP with $1 in one rename, keeping the old copy as the rollback.
swap_in() {
  local incoming="$1" staged="$APPS/.Chadmux.app.incoming"
  mkdir -p "$STATE/previous"
  rm -rf "$staged"
  ditto "$incoming" "$staged"
  quit_running
  if [ -d "$APP" ]; then
    rm -rf "$PREVIOUS"
    mv "$APP" "$PREVIOUS"
  fi
  mv "$staged" "$APP"
  register
}

record() { mkdir -p "$STATE"; printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2" >> "$STATE/history.tsv"; }

if [ "${1:-}" = "--rollback" ]; then
  [ -d "$PREVIOUS" ] || fail "no previous install to roll back to ($PREVIOUS)"
  held="$STATE/rollback-hold/Chadmux.app"
  rm -rf "$STATE/rollback-hold"; mkdir -p "$STATE/rollback-hold"
  ditto "$PREVIOUS" "$held"
  swap_in "$held"          # the copy being replaced becomes the new "previous"
  rm -rf "$STATE/rollback-hold"
  record rollback "$(awk -F'\t' '$2=="install"{print $3}' "$STATE/history.tsv" 2>/dev/null | tail -2 | head -1)"
  log "Rolled back: $APP (run --rollback again to undo)."
  exit 0
fi
[ $# -eq 0 ] || fail "usage: install-mac.sh [--rollback]"

COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "${CHADMUX_PREBUILT_APP:-}" ]; then
  BUILT="$CHADMUX_PREBUILT_APP"; BUILD=""
else
  TEAM="${CHADMUX_DEVELOPMENT_TEAM:-}"
  [ -n "$TEAM" ] || fail "set CHADMUX_DEVELOPMENT_TEAM to your local signing team (never committed)"
  if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
    log "Warning: the checkout has uncommitted changes; installing them as $COMMIT+dirty."
    COMMIT="$COMMIT+dirty"
  fi
  # One disposable build folder, deleted afterwards: native builds are large.
  BUILD="$(mktemp -d "${TMPDIR:-/tmp}/chadmux-mac-install.XXXXXX")"
  trap 'rm -rf "$BUILD"' EXIT
  log "Building Chadmux (Release, $COMMIT)…"
  xcodebuild -project "$ROOT/Chadmux.xcodeproj" -scheme ChadmuxMac -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$BUILD" \
    ${CHADMUX_PACKAGES:+-clonedSourcePackagesDirPath "$CHADMUX_PACKAGES"} \
    DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates build >"$BUILD/build.log" 2>&1 \
    || { tail -30 "$BUILD/build.log" >&2; fail "build failed"; }
  BUILT="$BUILD/Build/Products/Release/Chadmux.app"
fi

[ -d "$BUILT" ] || fail "no app at $BUILT"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BUILT/Contents/Info.plist")" = "$BUNDLE_ID" ] || fail "unexpected bundle id"
if [ -z "${CHADMUX_PREBUILT_APP:-}" ]; then
  codesign --verify --deep --strict "$BUILT" || fail "signature does not verify"
  codesign -d --entitlements - "$BUILT" 2>/dev/null | grep -q keychain-access-groups || fail "missing keychain entitlement"
fi

swap_in "$BUILT"
record install "$COMMIT"
# The build copy is deleted on exit; drop its Launch Services registration too.
[ -n "$BUILD" ] && [ -x "$LSREGISTER" ] && "$LSREGISTER" -u "$BUILT" >/dev/null 2>&1 || true
log "Installed $APP ($COMMIT). Previous copy kept for --rollback."
