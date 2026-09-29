# Installing Chadmux on the Mac

Chadmux for macOS is a local, team-signed Release build installed as
`/Applications/Chadmux.app`. It isn't notarized or distributed. The install
script builds it, checks it, and installs it with one rename. The copy it
replaces is kept for rollback.

```sh
CHADMUX_DEVELOPMENT_TEAM=YOUR_TEAM scripts/install-mac.sh   # install or update
scripts/install-mac.sh --rollback                           # back to the previous copy (again to undo)
```

Pass your local signing team on the command line (as for iOS); never commit it.
The first run creates a Mac development provisioning profile through
`-allowProvisioningUpdates`. To reuse an existing SwiftPM checkout, set
`CHADMUX_PACKAGES=/path/to/SourcePackages`.

## What the script does

1. Builds the `ChadmuxMac` scheme in Release into **one temporary build folder**,
   which is deleted when the script exits, whether or not the build succeeded.
   Native builds are several hundred MB and this Mac is short of space.
2. Refuses anything that isn't Chadmux (bundle id `com.ascinocco.chadmux.mac`),
   doesn't verify (`codesign --verify --deep --strict`), or lacks the keychain
   access-group entitlement.
3. Quits a running Chadmux politely, so drafts are checkpointed. tmux sessions
   keep running and tabs are restored on the next launch.
4. Moves the installed copy to
   `~/Library/Application Support/Chadmux/install/previous/` and renames the new
   build into `/Applications/Chadmux.app`.
5. Registers the new copy with Launch Services, so Finder and the Dock show its
   icon, and forgets the deleted build copy.
6. Appends the date, action and commit to `…/install/history.tsv`. An install
   from a checkout with uncommitted changes is recorded as `<commit>+dirty`.

## Updating keeps your data

The bundle id and signing team never change, so an update or rollback keeps:
- the Keychain items: the Mac's device key, each host's pinned host key, and
  transcription tokens;
- preferences: hosts, the dictation host and the sidebar state;
- drafts, images and the recovery archive.

Nothing needs re-pairing. A host's `authorized_keys` keeps working because
the device key is unchanged.

## Rolling back

`scripts/install-mac.sh --rollback` swaps the previous copy back in, and the
replaced copy becomes the new "previous". Running `--rollback` again undoes it.
Data is shared by both copies, so roll back only between versions whose saved
formats are compatible. So far every format change has been additive.

## Removing

Quit Chadmux and delete `/Applications/Chadmux.app` and
`~/Library/Application Support/Chadmux/install`. To remove its data as well,
delete the `com.ascinocco.chadmux` Keychain items and the Mac's Chadmux key
from each host's `authorized_keys`.

## Tests

`scripts/test-install-mac.py` checks install, update in place, rollback, undo,
and refusals (nothing to roll back to, a non-Chadmux bundle), using invented
bundles in temporary folders. It never touches `/Applications` or the real app.

The Mac UI tests (`ChadmuxMacUI` scheme) stay out of the default `ChadmuxMac`
test action by design: they take over the desktop and need the runner allowed
under Accessibility. The unit and real-SSH suites run natively with
`xcodebuild … -scheme ChadmuxMac test` and `scripts/test-transport.py --mac`.
