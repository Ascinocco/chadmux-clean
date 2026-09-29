#!/usr/bin/env python3
"""Run real SSH tests on a disposable loopback sshd; never use ~/.ssh or a live session.

With --linux the primary target is instead a disposable Linux container (Fedora,
native on Apple silicon: OpenSSH, tmux, bash) built from scripts/linux-fixture; the
macOS sshd still runs as the "Mac" and dictation host. Neither touches personal
hosts or sessions.
"""
import getpass
import json
import os
from pathlib import Path
import socket
import shutil
import subprocess
import tempfile
import time
import argparse
import shlex
import sys
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import threading

p = argparse.ArgumentParser()
p.add_argument('--resume-ui', action='store_true', help='Run foreground/cold resume UI test with disposable SSH')
p.add_argument('--native-ui', action='store_true', help='Run native gesture UI test against the real disposable SSH server')
p.add_argument('--manage-ui', action='store_true', help='Run the session create/end UI test against the real disposable SSH server (with --mac, also Mac dictation)')
p.add_argument('--multi-ui', action='store_true', help='Run the multi-host sidebar UI test: two hosts and an offline one')
p.add_argument('--linux', action='store_true', help='Use a disposable Linux container (Docker) as the primary host')
p.add_argument('--claude-tmux', default=os.path.expanduser('~/.claude/scripts/claude-tmux.sh'),
               help='claude-tmux script to exercise (default: the installed one); create/end tests skip without it')
p.add_argument('--only-testing', help='Override the -only-testing selector')
p.add_argument('--result-bundle', help='Optional fresh .xcresult path for evidence')
p.add_argument('--simulator', help='Installed iOS simulator UUID (iOS runs)')
p.add_argument('--mac', action='store_true', help='Run the integration tests natively on macOS (ChadmuxMac); needs CHADMUX_DEVELOPMENT_TEAM for signing')
p.add_argument('--derived-data', default='/tmp/chadmux-transport-build')
p.add_argument('--packages', help='Optional existing SwiftPM package checkout directory')
p.add_argument('--resident-token-file', help='Opt-in: private file containing the scoped token for the already-running companion server API on loopback 8420; never printed')
a = p.parse_args()
if a.mac:
    if a.resume_ui or a.native_ui: p.error('--mac runs the integration tests, --manage-ui and --multi-ui')
    TEAM = os.environ.get('CHADMUX_DEVELOPMENT_TEAM')
    if not TEAM: p.error('--mac needs CHADMUX_DEVELOPMENT_TEAM (your local signing team; never committed)')
elif not a.simulator: p.error('--simulator is required for iOS runs')

# The integration tests that apply to a Linux host. The loopback-API, stalled-SFTP
# and resident-dictation tests need the macOS fixture's local services.
LINUX_TESTS = [f'ChadmuxTests/SSHIntegrationTests/{name}' for name in (
    'testPinnedKeyAuthenticationPTYAndResize', 'testTwoSessionsSwitchDraftsAndDetachWithoutKilling',
    'testComposerDeliversLiteralPasteAndControlsThroughRealTmux', 'testPhotosUseSFTPAndInterruptedBatchNeverSubmits',
    'testNativeWheelTargetsRealPanesAndReturnCancelsOnlyActiveHistory', 'testForegroundResumeRealSSHIdentityNoReplayAndCancellation',
    'testCreateAndEndSessionsThroughClaudeTmux', 'testDictationFromAnotherHostUsesTheDictationHost')]


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def host_tools(directory, tmux_path, socket_path, claude=None):
    """A bin directory whose `tmux` is bound to one private server, plus a fake
    `claude` that only reports its folder, so no real Claude session starts."""
    directory.mkdir()
    (directory/'tmux').write_text('#!/bin/sh\nexec ' + shlex.quote(tmux_path) + ' -f /dev/null -S ' + shlex.quote(str(socket_path)) + ' "$@"\n')
    if claude is None:
        # Hide the cursor: a blinking terminal cursor keeps the app from idling for XCUITest.
        # Bracketed paste on, as Claude's prompt has it, so an explicit Send is accepted.
        (directory/'claude').write_text('#!/bin/sh\nprintf "FAKE-CLAUDE-READY %s\\n\\033[?25l\\033[?2004h" "$PWD"\nexec sleep 3600\n')
    else:
        (directory/'claude').symlink_to(claude)
    for name in ('tmux', 'claude'):
        if not (directory/name).is_symlink(): (directory/name).chmod(0o755)
    return directory


def slow_tmux_script(path, tmux_path):
    path.write_text('#!/bin/sh\ncase " $* " in *" attach-session "*) sleep 1;; esac\nexec ' + shlex.quote(tmux_path) + ' "$@"\n')
    path.chmod(0o755)
    return path


def without_claude(path, tools, script):
    """claude-tmux with only tmux on PATH: exercises the claude-missing error."""
    empty = path.parent/(path.name + '-bin')
    empty.mkdir()
    (empty/'tmux').symlink_to(tools/'tmux')
    path.write_text('#!/bin/sh\nPATH=' + shlex.quote(str(empty)) + ':/usr/bin:/bin exec ' + shlex.quote(str(script)) + ' "$@"\n')
    path.chmod(0o755)
    return path


with tempfile.TemporaryDirectory(prefix='chadmux-transport-') as tmp:
    # The real path: a Linux container bind-mounts it at this same path.
    root = Path(os.path.realpath(tmp))
    os.chmod(root, 0o700)
    port, stall_port, closed_port = free_port(), free_port(), free_port()  # closed_port: nothing listens (an offline host)
    for name in ('host', 'client'):
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(root/name)], check=True)
    tmux = shutil.which('tmux')
    if not tmux: raise RuntimeError('tmux is required for the transport fixture')
    tmux_socket = root/'tmux.sock'
    # A second, independent tmux server: the other host in macOS multi-host tests.
    tmux_socket2 = root/'tmux2.sock'
    capture = root/'capture.json'
    receiver = root/'receive.py'
    receiver.write_text('import sys,json\nfrom pathlib import Path\nlines=[sys.stdin.readline().rstrip("\\n") for _ in range(2)]\nPath(sys.argv[1]).write_text(json.dumps(lines))\nsys.stdin.read()\n')
    mac_bin = host_tools(root/'bin', tmux, tmux_socket)
    mac_bin2 = host_tools(root/'bin2', tmux, tmux_socket2, claude=mac_bin/'claude')
    claude_tmux = None
    if os.path.isfile(a.claude_tmux):
        # A copy inside the fixture folder, so a Linux container sees the same script.
        claude_tmux = root/'claude-tmux.sh'
        shutil.copyfile(os.path.realpath(a.claude_tmux), claude_tmux)
        claude_tmux.chmod(0o755)
    projects = root/"Projects with spaces"
    (projects/"phone project").mkdir(parents=True)
    uploads = root/"uploads with spaces"
    composer_capture = root/'composer.bin'
    composer_receiver = root/'composer.py'
    composer_receiver.write_text("import os,sys,tty\nfrom pathlib import Path\ntty.setraw(0)\nsys.stdout.write('\\x1b[?2004hREADY')\nsys.stdout.flush()\ncollected=b''\nwhile True:\n chunk=os.read(0,65536)\n if not chunk: break\n collected+=chunk\n Path(sys.argv[1]).write_bytes(collected)\n")
    config = root/'sshd_config'
    config.write_text(f'''Port {port}
ListenAddress 127.0.0.1
HostKey {root}/host
PidFile {root}/pid
AuthorizedKeysFile {root}/client.pub
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PermitTTY yes
LogLevel ERROR
Subsystem sftp internal-sftp
''')
    stall_script = root/'stall-sftp.py'
    stall_started, stall_closed = root/'stall-started', root/'stall-closed'
    stall_script.write_text("import sys,signal\nfrom pathlib import Path\nstarted,closed=map(Path,sys.argv[1:])\ndef finish(*args):\n closed.write_text('closed')\n raise SystemExit(0)\nsignal.signal(signal.SIGTERM,finish)\nsignal.signal(signal.SIGHUP,finish)\ntry:\n sys.stdin.buffer.read(9)\n started.write_text('started')\n while sys.stdin.buffer.read(1): pass\nfinally:\n closed.write_text('closed')\n")
    stall_config = root/'stall_sshd_config'
    stall_command = ' '.join(shlex.quote(str(x)) for x in [sys.executable,stall_script,stall_started,stall_closed])
    stall_config.write_text(config.read_text().replace(f'Port {port}',f'Port {stall_port}').replace(f'PidFile {root}/pid',f'PidFile {root}/stall-pid').replace('Subsystem sftp internal-sftp','Subsystem sftp '+stall_command))
    class API(BaseHTTPRequestHandler):
        def log_message(self, *args): pass
        def do_POST(self):
            body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
            valid = (self.path == '/transcriptions' and self.headers.get('Authorization') == 'Bearer fixture-transcription-token' and body == b'synthetic-recording')
            payload = json.dumps({'text':'Forwarded safely over SSH','duration_seconds':1.0} if valid else {'error':'invalid fixture request'}).encode()
            self.protocol_version = 'HTTP/1.1'
            self.send_response(200 if valid else 400)
            self.send_header('Content-Length',str(len(payload)))
            self.send_header('Connection','close')
            self.end_headers()
            self.wfile.write(payload)
            self.close_connection = True
    api = ThreadingHTTPServer(('127.0.0.1',0),API)
    api.daemon_threads = True
    api_thread = threading.Thread(target=api.serve_forever,daemon=True)
    api_thread.start()

    mac_host = dict(macPort=port, macTmux=tmux, macTmuxSocket=str(tmux_socket), macFixtureBin=str(mac_bin))
    # The primary target the integration tests use: the macOS sshd, or the container.
    primary = dict(port=port, tmux=tmux, tmuxSocket=str(tmux_socket), python=sys.executable,
                   slowTmux=str(slow_tmux_script(root/'slow-tmux', tmux)), fixtureBin=str(mac_bin),
                   noClaudeScript=str(without_claude(root/'claude-tmux-without-claude', mac_bin, claude_tmux)) if claude_tmux else None)
    arch_host = dict(archPort=port, archTmux=tmux, archTmuxSocket=str(tmux_socket2), archFixtureBin=str(mac_bin2))
    container = None
    if a.linux:
        # tmux sockets live in the container's own /tmp.
        linux_tmux, linux_socket = '/usr/bin/tmux', '/tmp/chadmux-tmux.sock'
        linux_bin = host_tools(root/'bin-linux', linux_tmux, linux_socket)
        # Every file the container needs must exist before it is copied in.
        primary = dict(port=None, tmux=linux_tmux, tmuxSocket=linux_socket, python='/usr/bin/python3',
                       slowTmux=str(slow_tmux_script(root/'slow-tmux-linux', linux_tmux)), fixtureBin=str(linux_bin),
                       noClaudeScript=str(without_claude(root/'claude-tmux-without-claude-linux', linux_bin, claude_tmux)) if claude_tmux else None)
        linux_config = root/'linux_sshd_config'
        linux_config.write_text(f'''Port 22
HostKey {root}/host
PidFile /run/chadmux-sshd.pid
AuthorizedKeysFile {root}/client.pub
AllowUsers {getpass.getuser()}
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PermitTTY yes
LogLevel ERROR
Subsystem sftp internal-sftp
''')
        image = f'chadmux-linux-fixture:{os.getuid()}'
        subprocess.run(['docker', 'build', '-q', '-t', image,
                        '--build-arg', f'FIXTURE_USER={getpass.getuser()}', '--build-arg', f'FIXTURE_UID={os.getuid()}',
                        str(Path(__file__).resolve().parent/'linux-fixture')], check=True, stdout=subprocess.DEVNULL)
        container = 'chadmux-fixture-' + uuid.uuid4().hex[:12]
        try:
            subprocess.run(['docker', 'create', '--name', container, '-p', '127.0.0.1::22', image,
                            '/usr/sbin/sshd', '-D', '-e', '-f', str(linux_config)], check=True, stdout=subprocess.DEVNULL)
            # A private copy at the same path, owned by the SSH user: Docker Desktop shows a
            # bind mount as root-owned, which sshd (reading keys as the user) cannot enter.
            # Every test reaches these files over SSH/SFTP, never from the Mac directly.
            # No macOS extended attributes: the container's filesystem rejects them.
            archive = subprocess.run(['tar', '--no-xattrs', '-C', '/', '-cf', '-', str(root).lstrip('/')], check=True,
                                     capture_output=True, env=dict(os.environ, COPYFILE_DISABLE='1')).stdout
            subprocess.run(['docker', 'cp', '-', f'{container}:/'], input=archive, check=True, stdout=subprocess.DEVNULL)
            subprocess.run(['docker', 'start', container], check=True, stdout=subprocess.DEVNULL)
            subprocess.run(['docker', 'exec', container, 'chown', '-R', f'{os.getuid()}', str(root)], check=True)
            mapped = subprocess.run(['docker', 'port', container, '22/tcp'], check=True, capture_output=True, text=True).stdout
        except BaseException:
            subprocess.run(['docker', 'rm', '-f', container], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
            raise
        linux_port = int(mapped.strip().splitlines()[0].rsplit(':', 1)[1])
        primary['port'] = linux_port
        arch_host = dict(archPort=linux_port, archTmux=linux_tmux, archTmuxSocket=linux_socket, archFixtureBin=str(linux_bin))

    fixture = root/'fixture.json'
    fixture.write_text(json.dumps(dict(hostKey=(root/'host.pub').read_text(), privateKey=(root/'client').read_text(), username=getpass.getuser(),
        capture=str(capture), receiver=str(receiver), apiPort=api.server_port, composerReceiver=str(composer_receiver), composerCapture=str(composer_capture),
        uploadRoot=str(uploads), stallPort=stall_port, stallStarted=str(stall_started), stallClosed=str(stall_closed),
        claudeTmux=str(claude_tmux) if claude_tmux else None, projectsDir=str(projects), closedPort=closed_port, linux=a.linux,
        **primary, **mac_host, **arch_host)))
    fixture.chmod(0o600)
    if a.resident_token_file:
        # Invented speech only. No microphone, user recordings or live sessions.
        text = 'Please inspect the failing unit test and explain the error before changing any code. '
        audio_paths = []
        for count in (1, 5):
            source, audio = root/f'speech-{count}.aiff', root/f'speech-{count}.m4a'
            subprocess.run(['say','-r','160','-o',str(source),text*count],check=True)
            subprocess.run(['ffmpeg','-nostdin','-v','error','-i',str(source),'-ar','16000','-ac','1','-c:a','aac','-b:a','64000',str(audio)],check=True)
            audio.chmod(0o600)
            audio_paths.append(str(audio))
        fields = json.loads(fixture.read_text())
        fields.update(residentTokenFile=str(Path(a.resident_token_file).resolve()), residentAudio=audio_paths)
        fixture.write_text(json.dumps(fields))

    def ready(target_port, process=None):
        """Wait for an SSH banner, not just an open socket (Docker proxies accept early)."""
        for _ in range(300):
            if process is not None and process.poll() is not None:
                raise RuntimeError('Disposable sshd failed: '+(root/'sshd.log').read_text())
            try:
                with socket.create_connection(('127.0.0.1', target_port), timeout=1) as conn:
                    conn.settimeout(2)
                    if conn.recv(4).startswith(b'SSH-'): return
            except OSError: pass
            time.sleep(.1)
        raise RuntimeError(f'Disposable sshd readiness timeout on port {target_port}')

    if a.only_testing: selection = [a.only_testing]
    elif a.resume_ui: selection = ['ChadmuxUITests/ChadmuxUITests/testForegroundResumeAgainstLiveTmux']
    elif a.native_ui: selection = ['ChadmuxUITests/ChadmuxUITests/testNativeGesturesAgainstLiveTmux']
    elif a.manage_ui: selection = ['ChadmuxUITests/ChadmuxUITests/testCreateAndEndSessionsAgainstLiveTmux']
    elif a.multi_ui: selection = ['ChadmuxUITests/ChadmuxUITests/testMultipleHostsInOneSidebarAgainstLiveTmux']
    elif a.linux: selection = LINUX_TESTS + (['ChadmuxTests/SSHIntegrationTests/testMacTerminalDropUploadsAndPastesThePath'] if a.mac else [])
    else: selection = ['ChadmuxTests/SSHIntegrationTests']
    if a.mac: selection = [name.replace('ChadmuxTests/', 'ChadmuxMacTests/', 1).replace('ChadmuxUITests/ChadmuxUITests/', 'ChadmuxMacUITests/ChadmuxMacUITests/', 1)
                           .replace('testMultipleHostsInOneSidebarAgainstLiveTmux', 'testHostsTabsAndShortcutsAgainstLiveTmux') for name in selection]
    if a.mac and a.manage_ui and not a.only_testing:
        selection.append('ChadmuxMacUITests/ChadmuxMacUITests/testDictationPastesIntoTheTerminalWithoutEnterAgainstLiveTmux')
    # Mac UI tests drive the real desktop (the runner needs Accessibility); they have their own scheme.
    mac_scheme = 'ChadmuxMacUI' if a.mac and (a.manage_ui or a.multi_ui) else 'ChadmuxMac'

    with (root/'sshd.log').open('w') as log:
        server = subprocess.Popen(['/usr/sbin/sshd', '-D', '-e', '-f', str(config)], stdout=log, stderr=log)
        stalled = None
        try:
            stalled = subprocess.Popen(['/usr/sbin/sshd','-D','-e','-f',str(stall_config)],stdout=log,stderr=log)
            ready(port, server)
            if container: ready(primary['port'])
            target = (['-scheme',mac_scheme,'-destination','platform=macOS,arch=arm64',
                       f'DEVELOPMENT_TEAM={TEAM}','CODE_SIGN_STYLE=Automatic','-allowProvisioningUpdates'] if a.mac else
                      ['-scheme','Chadmux','-destination',f'platform=iOS Simulator,id={a.simulator}','CODE_SIGN_IDENTITY=-','CODE_SIGNING_ALLOWED=YES'])
            subprocess.run(['xcodebuild','-project','Chadmux.xcodeproj',*target,
                '-derivedDataPath',a.derived_data,*(['-clonedSourcePackagesDirPath',a.packages] if a.packages else []),
                f'CHADMUX_TRANSPORT_FIXTURE={fixture}',
                *[f'-only-testing:{name}' for name in selection],
                *(['-resultBundlePath', a.result_bundle] if a.result_bundle else []),'test'],check=True,timeout=1800 if container else 900)
        finally:
            api.shutdown()
            api.server_close()
            # Own cleanup outside XCTest/SSH: a crashed test must not leave a daemon.
            for sock in (tmux_socket, tmux_socket2):
                subprocess.run([tmux, '-S', str(sock), 'kill-server'],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
            if container:
                subprocess.run(['docker', 'rm', '-f', container], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
            for process in [server, stalled]:
                if process is None: continue
                process.terminate()
                try: process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
