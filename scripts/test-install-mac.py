#!/usr/bin/env python3
"""Tests scripts/install-mac.sh (install, update in place, rollback and undo)
with invented app bundles in temporary folders. Never touches /Applications,
the real app, the Keychain or Launch Services."""
import os, plistlib, subprocess, sys, tempfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / 'install-mac.sh'

def fake_app(root: Path, marker: str, bundle_id='com.ascinocco.chadmux.mac') -> Path:
    app = root / marker / 'Chadmux.app'
    (app / 'Contents/MacOS').mkdir(parents=True)
    with open(app / 'Contents/Info.plist', 'wb') as f:
        plistlib.dump({'CFBundleIdentifier': bundle_id, 'CFBundleName': 'Chadmux'}, f)
    (app / 'Contents/MacOS/Chadmux').write_text(marker)
    return app

def run(env, *args, ok=True):
    result = subprocess.run(['bash', str(SCRIPT), *args], env=env, capture_output=True, text=True)
    if ok and result.returncode != 0: sys.exit(f'FAIL {args}: {result.stderr}')
    if not ok and result.returncode == 0: sys.exit(f'FAIL {args}: expected a refusal')
    return result

def installed(apps: Path) -> str: return (apps / 'Chadmux.app/Contents/MacOS/Chadmux').read_text()

with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp); apps = tmp / 'Applications'; apps.mkdir(); state = tmp / 'state'
    env = dict(os.environ, CHADMUX_APPLICATIONS_DIR=str(apps), CHADMUX_INSTALL_STATE_DIR=str(state))
    run(dict(env, CHADMUX_PREBUILT_APP=''), '--rollback', ok=False)                       # nothing to roll back to
    run(dict(env, CHADMUX_PREBUILT_APP=str(fake_app(tmp, 'wrong', 'com.example.other'))), ok=False)  # not Chadmux
    assert not (apps / 'Chadmux.app').exists(), 'a refused install leaves nothing behind'

    run(dict(env, CHADMUX_PREBUILT_APP=str(fake_app(tmp, 'v1'))))
    assert installed(apps) == 'v1'
    run(dict(env, CHADMUX_PREBUILT_APP=str(fake_app(tmp, 'v2'))))
    assert installed(apps) == 'v2', 'update in place'
    assert (state / 'previous/Chadmux.app/Contents/MacOS/Chadmux').read_text() == 'v1', 'previous kept for rollback'
    assert not list(apps.glob('.Chadmux.app*')), 'no staging copy left behind'

    run(dict(env, CHADMUX_PREBUILT_APP='x'), '--rollback')
    assert installed(apps) == 'v1', 'rollback restores the previous copy'
    run(dict(env, CHADMUX_PREBUILT_APP='x'), '--rollback')
    assert installed(apps) == 'v2', 'a second rollback undoes the first'
    history = (state / 'history.tsv').read_text().splitlines()
    assert [line.split('\t')[1] for line in history] == ['install', 'install', 'rollback', 'rollback'], history
    print('install-mac.sh: 9 checks passed')
