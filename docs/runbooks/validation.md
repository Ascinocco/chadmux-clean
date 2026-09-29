# Validating a change

What to run before opening a PR, what evidence to put in it, and what the owner tests
by hand before a merge. Commands are in [testing.md](testing.md).

## Pick the checks by what the change touches

Look at the paths in `git diff --stat origin/main...HEAD`.

| Touches | Required automated checks | Hands-on |
| --- | --- | --- |
| `ChadmuxMac/`, `ChadmuxMacTests/`, `ChadmuxMacUITests/` only | Mac unit; Mac UI offline; `--mac`; `--mac --linux`; `--mac --multi-ui` and `--mac --manage-ui` if the window, sidebar or sessions changed | Mac |
| iOS-only views (`ContentView`, `ComposerView`, `PhotoPicker`, `NativeTerminalView`, `SessionViews`, …) or `ChadmuxUITests/` | iOS unit and UI on **SE and Pro Max**; the live UI suites that cover the area (`--multi-ui`, `--manage-ui`, `--resume-ui`, `--native-ui`) on both | iPhone |
| Shared `Chadmux/` code (transport, tmux, hosts, `claude-tmux`, storage, media, dictation) | **everything**: both platforms' unit tests, iOS UI on both sizes, `--simulator` and `--linux`, `--mac` and `--mac --linux`, and every live UI suite that exercises the changed path | both |
| Only a `#if DEBUG` fixture or `test-transport.py` | the suites that use the fixture | none |
| Docs only | read-through; check commands and paths against the code | none |

"No regressions on mobile" means the iOS suites **ran** (check the skip counts)
and passed on both simulator sizes. For a Mac-only change, show that no file iOS
compiles changed (`git diff --stat`); that is the evidence the iOS results still
apply.

## Before opening the PR

1. Rebase on current `origin/main`; the PR diff should hold only this task.
2. Run the checks above in the task worktree, with task-owned DerivedData and
   simulators.
3. Grep your diff for anything private: team ids, device ids, real addresses,
   tokens, real session content.
4. Update `PROJECT.md` (behaviour/contract) and the runbooks (procedure) in the
   same PR when behaviour changes.
5. Clean up builds and simulators ([testing.md](testing.md#cleanup-every-time)).

## PR evidence

Put this in the PR description:

- the head commit tested;
- each suite run, with passed / failed / **skipped** counts, on which device or
  simulator;
- for the real SSH suites, the mode (`--mac --linux` etc.);
- what was not tested and why (for example "hardware microphone: pilot");
- a `Jyra-Ticket: <uuid>` line, with a matching trailer in commits.

Never write ✅ for a run you didn't read the counts of. A silently skipped test
once passed as ✅ for weeks (a stale fixture key).

## Review and merge

1. **Factory code review** runs on every Chadmux PR: two Sonnet seven-lens
   reviews through the review runner, validated and stamped by the Opus review
   lead (the factory's code-review protocol). A follow-up commit gets an
   incremental round from the previous stamped head. If the review bundle is
   over the runner's size limit, ask the owner; don't trim files out.
2. Answer every finding: fixed (with the commit), refuted (with the reason), or
   deferred (with a follow-up ticket).
3. **Install the PR head for the owner**: `install-mac.sh` for the Mac, a device
   install for the iPhone. Tell them the commit and a short test script (below).
4. Merge only after the stamp is on the **current head** and the owner has said to
   merge. Use `gh pr merge --match-head-commit <head>` and check that the merge
   commit's tree equals the reviewed head.
5. **Pointer PR:** if Chadmux is developed inside a factory repository that pins
   it as a submodule, update that pin to the merged commit following the factory's
   own runbook.
6. Record on the Jyra ticket, and move it to done only when the owner says so.

## Hands-on scripts for the owner

Give the owner the part that matches the change. Use invented prompts and images.

**Mac.** Say which commit is installed.
- Connect This Mac and a server; open a session on each; switch with Cmd-1/2.
- `+` a session in a scratch folder, rename it, end it.
- Drop a screenshot onto a Claude session. It shows `[Image #N]` and nothing is
  sent. ⌘V an image does the same. A text ⌘V pastes text. A mixed drop reports
  the skipped item.
- Cmd-W closes a tab immediately and the session keeps running (check from the
  iPhone or `tmux ls`).
- Dictation on a This Mac and a server session: click the mic (allow the
  microphone the first time), say an invented prompt, click again. The text lands
  in Claude's input and nothing is sent; Esc during a recording pastes nothing.
- Quit and relaunch: tabs and the selected host come back.

**iPhone.** Say which commit is installed.
- Open the same session as the Mac; both stay attached.
- Type a multiline prompt and Send; control-row keys work.
- Attach two photos, remove one, Send: Claude sees one image.
- Lock the phone, come back: the same session reconnects, the draft is kept,
  nothing is resent.
- Add or edit a host; one host offline doesn't block the others.
- Dictation is unavailable until the planned follow-up. Skip it, or confirm it reports that
  clearly.

Record hardware results in the pilot tables ([iphone-pilot.md](../iphone-pilot.md),
[mac-pilot.md](../mac-pilot.md)), marking them as observed by the owner, separate from
automated evidence.
