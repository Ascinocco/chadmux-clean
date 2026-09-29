#if DEBUG
import Foundation
import Crypto
import Citadel
import NIOSSH
import Security

/// Disposable UI+SSH fixture only. Never enabled by ordinary app launch.
@MainActor
enum NativeScrollFixture {
    struct Input: Decodable {
        let hostKey, privateKey, username, tmux, tmuxSocket: String; let port: Int
        let claudeTmux, fixtureBin: String?
        let macTmux, macTmuxSocket, macFixtureBin, archTmux, archTmuxSocket, archFixtureBin: String?
        let macPort, archPort, closedPort: Int?
        let uploadRoot: String?
    }
    static func workspace() -> SessionWorkspace? {
        #if !(targetEnvironment(simulator) || os(macOS))
        return nil
        #else
        let resumeFixture = ProcessInfo.processInfo.arguments.contains("--resume-live-fixture")
        let manageFixture = ProcessInfo.processInfo.arguments.contains("--session-manage-live-fixture")
        guard (resumeFixture || manageFixture || ProcessInfo.processInfo.arguments.contains("--native-scroll-live-fixture")),
              let path = ProcessInfo.processInfo.environment["CHADMUX_TRANSPORT_FIXTURE"], path.hasPrefix("/"),
              let data = try? Data(contentsOf:URL(fileURLWithPath:path)),
              let input = try? JSONDecoder().decode(Input.self,from:data) else { return nil }
        let name = resumeFixture ? "com.chadmux.resume-fixture.\(input.port)" : manageFixture ? "com.chadmux.manage-fixture" : "com.chadmux.native-fixture"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name,isDirectory:true)
        let reset = !resumeFixture || ProcessInfo.processInfo.arguments.contains("--reset-resume-fixture")
        if reset {
            SecItemDelete([kSecClass:kSecClassGenericPassword,kSecAttrService:name] as CFDictionary)
            UserDefaults(suiteName:name)?.removePersistentDomain(forName:name)
            try? FileManager.default.removeItem(at:directory)
        }
        let store = SecretStore(service:name)
        let control = MacTransport(preferences:UserDefaults(suiteName:name)!,secrets:store)
        let profile = MacConnection(host:"127.0.0.1",port:input.port,username:input.username)
        do {
            let key = try Curve25519.Signing.PrivateKey(sshEd25519:input.privateKey)
            try store.write(key.rawRepresentation,account:"device-ed25519")
            try store.write(Data(String(openSSHPublicKey:try NIOSSHPublicKey(openSSHPublicKey:input.hostKey)).utf8),account:profile.trustID)
            try control.save(profile)
        } catch { return nil }
        let q = SSHPrimitives.shellQuote
        let tmux = "/usr/bin/env LC_ALL=en_US.UTF-8 " + q(input.tmux)+" -u -f /dev/null -S "+q(input.tmuxSocket)
        if manageFixture { return manageWorkspace(input:input,control:control,tmux:tmux,directory:directory) }
        let workspace = SessionWorkspace(connection:control,tmuxCommand:tmux,
            recovery:resumeFixture ? RecoveryStore(directory:directory.appendingPathComponent("drafts")) : nil,
            media:MediaStore(directory:directory.appendingPathComponent("images")))
        if resumeFixture && !reset { return workspace }
        Task {
            workspace.becameActive()
            control.connect(openShell:false)
            for _ in 0..<100 {
                if control.connected { break }
                try? await Task.sleep(nanoseconds:100_000_000)
            }
            guard let client = control.client, control.connected else { return }
            do {
                let output = "i=0; while [ $i -lt 180 ]; do printf 'nativecopy HISTORY-%03d café 你好\\n' \"$i\"; i=$((i+1)); done; printf '\\033[?25l'; sleep 600"
                _ = try await client.executeCommand(tmux+" new-session -d -s native-ui -x 80 -y 24 "+q(output),maxResponseSize:1024)
                _ = try await client.executeCommand(tmux+" set-option -t native-ui mouse on",maxResponseSize:1024)
                _ = try await client.executeCommand(tmux+" set-option -t native-ui status-right fixture",maxResponseSize:1024)
                await workspace.refresh()
                guard let session = workspace.sessions.first(where:{$0.name=="native-ui"}) else { return }
                if resumeFixture {
                    _ = try await client.executeCommand(tmux+" new-session -d -s resume-second -x 80 -y 24 "+q("printf 'SECOND-SESSION-READY\\n'; sleep 600"),maxResponseSize:1024)
                    await workspace.refresh()
                    guard let other = workspace.sessions.first(where:{$0.name=="resume-second"}) else { return }
                    workspace.select(other); await workspace.waitForResume()
                    workspace.selected?.draft = "Second retained draft"
                }
                workspace.select(session)
                workspace.selected?.transport.nativeScrollFixture = !resumeFixture
                if resumeFixture {
                    await workspace.waitForResume()
                    workspace.selected?.draft = "Unsent resume draft"
                    workspace.sidebarExpanded = false
                }
            } catch { control.errorMessage = "Synthetic SSH fixture could not start." }
        }
        return workspace
        #endif
    }

    /// Multi-host fixture: "Mac" and "Arch" are two independent tmux servers
    /// behind the disposable sshd, each with a session called shared-name;
    /// "Offline" points at a closed port. Never touches personal sessions.
    static func multiHost() -> HostsModel? {
        #if !(targetEnvironment(simulator) || os(macOS))
        return nil
        #else
        guard ProcessInfo.processInfo.arguments.contains("--multi-host-live-fixture"),
              let path = ProcessInfo.processInfo.environment["CHADMUX_TRANSPORT_FIXTURE"], path.hasPrefix("/"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let input = try? JSONDecoder().decode(Input.self, from: data),
              let script = input.claudeTmux, let closedPort = input.closedPort,
              let macPort = input.macPort, let macTmux = input.macTmux, let macSocket = input.macTmuxSocket, let macBin = input.macFixtureBin,
              let archPort = input.archPort, let archTmux = input.archTmux, let archSocket = input.archTmuxSocket, let archBin = input.archFixtureBin else { return nil }
        let name = "com.chadmux.multi-fixture"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: name] as CFDictionary)
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: directory)
        let store = SecretStore(service: name), preferences = UserDefaults(suiteName: name)!
        let macLive = MacConnection(host: "127.0.0.1", port: macPort, username: input.username)
        let archLive = MacConnection(host: "127.0.0.1", port: archPort, username: input.username)
        let offline = MacConnection(host: "127.0.0.1", port: closedPort, username: input.username)
        do {
            let key = try Curve25519.Signing.PrivateKey(sshEd25519: input.privateKey)
            try store.write(key.rawRepresentation, account: "device-ed25519")
            let pin = Data(String(openSSHPublicKey: try NIOSSHPublicKey(openSSHPublicKey: input.hostKey)).utf8)
            try store.write(pin, account: macLive.trustID); try store.write(pin, account: archLive.trustID)
        } catch { return nil }
        let q = SSHPrimitives.shellQuote
        let voice = VoiceCoordinator()
        func workspace(_ connection: MacConnection, tmux: String, socket: String, bin: String) -> SessionWorkspace {
            SessionWorkspace(connection: MacTransport(preferences: preferences, secrets: store, profile: connection),
                tmuxCommand: "/usr/bin/env LC_ALL=en_US.UTF-8 " + q(tmux) + " -u -f /dev/null -S " + q(socket),
                claudeTmux: ClaudeTmux(scriptPath: script, pathPrefix: bin),
                media: MediaStore(directory: directory.appendingPathComponent("images")), voice: voice)
        }
        // With --linux, "Arch" is the disposable Arch Linux container.
        let mac = workspace(macLive, tmux: macTmux, socket: macSocket, bin: macBin)
        let arch = workspace(archLive, tmux: archTmux, socket: archSocket, bin: archBin)
        let unreachable = workspace(offline, tmux: macTmux, socket: macSocket, bin: macBin)
        let model = HostsModel(fixture: [("Mac", mac), ("Arch", arch), ("Offline", unreachable)])
        Task {
            model.becameActive()
            for (label, host) in [("MAC", mac), ("ARCH", arch)] {
                host.connection.connect(openShell: false)
                for _ in 0..<100 where !host.connection.connected { try? await Task.sleep(nanoseconds: 100_000_000) }
                guard let client = host.connection.client else { continue }
                for session in ["shared-name", label.lowercased() + "-only"] {
                    // Hidden cursor: a blinking one keeps the app from idling for XCUITest.
                    let body = "printf '" + label + "-HOST " + session + "\\n\\033[?25l'; exec sleep 3600"
                    _ = try? await client.executeCommand(host.tmuxCommand + " new-session -d -s " + q(session) + " -x 80 -y 24 " + q(body), maxResponseSize: 1024)
                }
                await host.refresh()
            }
            unreachable.retryConnection()
            model.sidebarExpanded = true
            // Publish what the on-screen tab is running, and on which tmux server.
            while !Task.isCancelled {
                if let host = model.selectedWorkspace, let id = host.selected?.id, let client = host.connection.client {
                    let fields = " display-message -p -t " + q(id) + " '#{session_name}|#{pane_start_command}|#{pane_current_path}'"
                    let result = try? await client.executeCommand(host.tmuxCommand + fields + " 2>/dev/null; true", maxResponseSize: 4096)
                    let observed = host.hostLabel + "|" + (result.map { String(buffer: $0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? "")
                    if observed != host.fixtureEvidence { host.fixtureEvidence = observed }
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        return model
        #endif
    }

    /// Mac dictation UI test (--dictation-live-fixture with the manage fixture):
    /// an injected recorder that never opens the microphone, and a transcriber
    /// that returns this invented text, with a newline and control characters
    /// the paste must strip. Only the pasted text reaches the fixture session.
    static var dictationToken: String? {
        #if os(macOS)
        guard ProcessInfo.processInfo.arguments.contains("--dictation-live-fixture") else { return nil }
        return ProcessInfo.processInfo.environment["CHADMUX_DICTATION_TOKEN"].flatMap { $0.allSatisfy { $0.isLetter || $0.isNumber } ? $0 : nil }
        #else
        return nil
        #endif
    }
    /// What the fixture session should show once the transcript is pasted.
    static func dictationPasted(_ token: String) -> String { "dictated " + token + " second line[2Jend" }
    @MainActor
    final class FixtureRecording: VoiceRecording {
        func start(finished: @escaping (Bool) -> Void) throws {}
        func stop() throws -> Data { Data("invented fixture audio".utf8) }
        func discard() {}
    }
    static func routeDictation(_ model: HostsModel) {
        guard let token = dictationToken else { return }
        model.voice.route = { _ in .ready { _ in
            try await Task.sleep(nanoseconds: 300_000_000)
            return "dictated " + token + "\r\nsecond line\u{1b}[2J\u{07}end"
        } }
    }

    /// Create/end fixture: two listed sessions, one of which ("replace-me") is
    /// replaced on the host after listing, so ending it must be refused.
    private static func manageWorkspace(input:Input,control:MacTransport,tmux:String,directory:URL) -> SessionWorkspace? {
        guard let script = input.claudeTmux, let bin = input.fixtureBin else { return nil }
        let q = SSHPrimitives.shellQuote
        let dictation = dictationToken
        let workspace = SessionWorkspace(connection:control,tmuxCommand:tmux,
            claudeTmux:ClaudeTmux(scriptPath:script,pathPrefix:bin),
            media:MediaStore(directory:directory.appendingPathComponent("images")),
            voice:dictation == nil ? nil : VoiceCoordinator(permission:{ true },makeRecording:{ FixtureRecording() }))
        // Mac terminal image uploads go to the fixture's private directory, never ~/.chadmux.
        if let root = input.uploadRoot { workspace.uploadRoot = root }
        Task {
            workspace.becameActive()
            control.connect(openShell:false)
            for _ in 0..<100 where !control.connected { try? await Task.sleep(nanoseconds:100_000_000) }
            guard let client = control.client, control.connected else { return }
            do {
                if dictation != nil {
                    // Only its own session, whatever an earlier test left on this tmux server. cat
                    // echoes what is typed and repeats a line only after Enter; mouse on for "Live".
                    let body = "i=0; while [ $i -lt 120 ]; do echo HISTORY-$i; i=$((i+1)); done; printf '\\033[?25l'; exec /bin/cat"
                    _ = try await client.executeCommand(tmux+" kill-session -t '=dictation' 2>/dev/null; "+tmux+" new-session -d -s dictation -x 80 -y 24 "+q(body)+" && "+tmux+" set-option -t dictation mouse on",maxResponseSize:1024)
                    await workspace.refresh()
                } else {
                    for session in ["existing","replace-me"] {
                        _ = try await client.executeCommand(tmux+" new-session -d -s "+q(session)+" -x 80 -y 24 /bin/cat",maxResponseSize:1024)
                    }
                    await workspace.refresh()
                    _ = try await client.executeCommand(tmux+" kill-session -t '=replace-me' && "+tmux+" new-session -d -s replace-me /bin/cat",maxResponseSize:1024)
                }
                workspace.sidebarExpanded = true
                var copied: Set<String> = []
                var heard = -1
                var repeats = 0
                // Publish what the selected session is actually running, for the UI test.
                while !Task.isCancelled {
                    if let id = workspace.selected?.id, control.connected {
                        let fields = " display-message -p -t "+q(id)+" '#{pane_start_command}|#{pane_current_path}|#{pane_current_command}'"
                        let result = try? await client.executeCommand(tmux+fields+" 2>/dev/null; true",maxResponseSize:4096)
                        let observed = result.map { String(buffer:$0).trimmingCharacters(in:.whitespacesAndNewlines) } ?? ""
                        // Publish only changes: constant updates would keep the UI from idling for XCUITest.
                        if observed != workspace.fixtureEvidence { workspace.fixtureEvidence = observed }
                        #if os(macOS)
                        // Mac copy/paste test: once "copy-request TOKEN" is pasted into the pane, tmux
                        // copies "copied TOKEN" to its clients' clipboards with OSC 52, as a mouse copy does.
                        let pane = try? await client.executeCommand(tmux+" capture-pane -p -t "+q(id)+" 2>/dev/null; true",maxResponseSize:65536)
                        if let text = pane.map({ String(buffer:$0) }), let marker = text.range(of:"copy-request ") {
                            let token = String(text[marker.upperBound...].prefix { $0.isLetter || $0.isNumber })
                            if !token.isEmpty, copied.insert(token).inserted {
                                _ = try? await client.executeCommand(tmux+" set-buffer -w "+q("copied "+token),maxResponseSize:1024)
                            }
                        }
                        // Dictation test: how many times the pasted transcript appears in the
                        // dictation pane (1 = pasted once with no Enter; cat repeats it after Enter).
                        // Repeated every few seconds: OSC 52 only reaches a client that is attached.
                        if let token = dictation, workspace.selected?.name == "dictation", workspace.selected?.transport.connected == true,
                           let text = pane.map({ String(buffer:$0) }) {
                            let count = text.components(separatedBy:dictationPasted(token)).count - 1
                            repeats += 1
                            if count != heard || repeats >= 10 {
                                heard = count; repeats = 0
                                _ = try? await client.executeCommand(tmux+" set-buffer -w "+q("heard "+token+" x\(count)"),maxResponseSize:1024)
                            }
                        }
                        #endif
                    }
                    try await Task.sleep(nanoseconds:300_000_000)
                }
            } catch { control.errorMessage = "Synthetic SSH fixture could not start." }
        }
        return workspace
    }
}
#endif
