import SwiftUI
import SwiftTerm
import Citadel
import Crypto
import NIO
import NIOSSH

enum ConnectionFailure: Error, Equatable {
    case invalidProfile, invalidSession, verificationRequired, changedHost, authentication
    case protectedData, sessionUnavailable, network, cancelled, timeout
    var isTransient: Bool { self == .network || self == .timeout }
    static func attachment(_ error:Error) -> ConnectionFailure {
        if let classified = error as? ConnectionFailure { return classified }
        if error is CancellationError { return .cancelled }
        if error is MacTransport.SessionReplaced || error is SSHClient.CommandFailed || error is TTYSTDError { return .sessionUnavailable }
        return .network
    }
}

@MainActor
final class MacTransport: ObservableObject, @preconcurrency TerminalViewDelegate {
    @Published var profile: MacConnection { didSet { if oldValue != profile { onProfileChanged?(oldValue) } } }
    @Published var status = "Disconnected"
    @Published var connected = false { didSet { terminal.inputAvailable = connected } }
    @Published var showLiveReturn = false
    @Published var returningLive = false
    @Published var connecting = false
    @Published var errorMessage: String?
    @Published var unknownHost: UnknownHost?
    @Published var publicKey = ""
    #if DEBUG
    var nativeScrollFixture = false
    @Published var nativeScrollPosition = ""
    @Published var nativeScrollEvidence = "Waiting for live terminal"
    #endif
    let terminal = PlatformTerminalView(frame: .zero)
    let secrets: SecretStore
    let preferences: UserDefaults
    private(set) var client: SSHClient?
    private var writer: TTYStdinWriter?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private var connectionCompletion: ((Result<Void,ConnectionFailure>) -> Void)?
    var onConnectionLost: (() -> Void)?
    var onProfileChanged: ((MacConnection) -> Void)?
    private var pendingProfile: MacConnection?
    private var attachedClientPID: String?
    private var requestedSessionID: String?
    private var requestedShell = true
    private var requestedInstance: String?
    private var requestedTmuxCommand = TmuxSessions.command

    /// The app's preferences. UI tests use a separate suite, reset at most once
    /// per launch: every host's transport shares it with the saved host list.
    static func appPreferences() -> UserDefaults {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            let suite = UserDefaults(suiteName: "com.chadmux.ui-tests")!
            if ProcessInfo.processInfo.arguments.contains("--reset-test-profile") && !resetUITestPreferences {
                resetUITestPreferences = true
                suite.removePersistentDomain(forName: "com.chadmux.ui-tests")
            }
            return suite
        }
        #endif
        return .standard
    }
    private static var resetUITestPreferences = false

    /// `profile` is the host this transport serves; without one it reads the
    /// legacy single saved connection (tests and fixtures).
    init(preferences: UserDefaults? = nil, secrets: SecretStore = SecretStore(), profile: MacConnection? = nil) {
        let preferences = preferences ?? Self.appPreferences()
        self.preferences = preferences
        self.secrets = secrets
        self.profile = profile ?? preferences.data(forKey: "mac-connection")
            .flatMap { try? JSONDecoder().decode(MacConnection.self, from: $0) } ?? MacConnection()
        terminal.terminalDelegate = self
        terminal.selectionBounds = { [weak self] point in await self?.selectionRectangle(at:point) }
        terminal.remoteScroll = { [weak self] ticks, point in
            guard let self, self.connected else { return }
            if self.terminal.getTerminal().mouseMode != .off {
                self.showLiveReturn = true
                self.terminal.wheel(ticks, at: point)
            } else {
                self.errorMessage = "This session is not accepting scroll-wheel input. Enable tmux mouse support for this session to scroll its history."
            }
        }
        terminal.useChadmuxColors()
        do { publicKey = SSHPrimitives.authorizedKey(try secrets.deviceKey()) }
        catch { errorMessage = "The device key could not be opened. Unlock the phone and try again." }
    }

    func save(_ updated: MacConnection) throws {
        guard updated.isValid else { throw InvalidConnection() }
        preferences.set(try JSONEncoder().encode(updated), forKey: "mac-connection")
        profile = updated
    }

    func connect(sessionID: String? = nil, expectedInstance: String? = nil, openShell: Bool = true, tmuxCommand: String = TmuxSessions.command,
                 requestID: UUID = UUID(), completion: ((Result<Void,ConnectionFailure>) -> Void)? = nil) {
        guard profile.isValid else { completion?(.failure(.invalidProfile)); return }
        guard !Task.isCancelled else { completion?(.failure(.cancelled)); return }
        if connected { completion?(.success(())); return }
        guard !connecting else { completion?(.failure(.cancelled)); return }
        if let sessionID, !TmuxSessions.validID(sessionID) { errorMessage = "Invalid tmux session identifier."; completion?(.failure(.invalidSession)); return }
        connectionCompletion = completion
        requestedSessionID = sessionID; requestedInstance = expectedInstance; requestedShell = openShell; requestedTmuxCommand = tmuxCommand
        let attempt = requestID, target = profile
        generation = attempt
        connecting = true; status = "Connecting…"; errorMessage = nil; unknownHost = nil
        operation = Task {
            var opened: SSHClient?
            var verification: PinnedHostValidator?
            do {
                let privateKey = try secrets.deviceKey()
                let pin = try secrets.read(target.trustID).flatMap { String(data: $0, encoding: .utf8) }
                let validator = PinnedHostValidator(expected: pin)
                verification = validator
                var settings = SSHClientSettings(host: target.host, port: target.port,
                    authenticationMethod: { .ed25519(username: target.username, privateKey: privateKey) },
                    hostKeyValidator: .custom(validator))
                settings.connectTimeout = .seconds(15)
                let ssh = try await SSHClient.connect(to: settings)
                opened = ssh
                guard generation == attempt, !Task.isCancelled else { try? await ssh.close(); return }
                client = ssh
                ssh.onDisconnect { [weak self] in
                    Task { @MainActor in
                        guard let self, self.generation == attempt else { return }
                        self.connected = false; self.writer = nil; self.status = "Disconnected"
                        self.finishConnection(.failure(.network))
                        self.onConnectionLost?()
                    }
                }
                if !openShell {
                    connected = true; connecting = false; status = "Connected"
                    finishConnection(.success(()))
                    return
                }
                if let sessionID {
                    _ = try await ssh.executeCommand(tmuxCommand + " has-session -t " + SSHPrimitives.shellQuote(sessionID), maxResponseSize: 8192)
                    if let expectedInstance {
                        let actual = try await TmuxSessions.readInstance(using: ssh, id: sessionID, command: tmuxCommand)
                        guard actual == expectedInstance else { throw SessionReplaced() }
                    }
                }
                var completed = false
                do {
                    try await ssh.withPTY(.init(wantReply: true, term: "xterm-256color",
                        terminalCharacterWidth: terminal.getTerminal().cols, terminalRowHeight: terminal.getTerminal().rows,
                        terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: .init([:]))) { inbound, outbound in
                        guard self.generation == attempt else { return }
                        let marker = "CHADMUX-" + UUID().uuidString
                        var startup = ""
                        var attachmentCheck: Task<Void, Never>?
                        let deadline: Task<Void, Never>? = sessionID == nil ? nil : Task {
                            try? await Task.sleep(nanoseconds: 15_000_000_000)
                            guard !Task.isCancelled, self.generation == attempt, !self.connected else { return }
                            self.finishConnection(.failure(.timeout))
                            self.disconnect(); self.status = "Session unavailable"
                            self.errorMessage = "tmux did not finish attaching. Refresh sessions and reconnect. Your draft is retained."
                        }
                        defer { attachmentCheck?.cancel(); deadline?.cancel() }
                        if let sessionID {
                            // exec preserves this shell PID. Readiness is checked against
                            // that exact tmux client, not a login shell's paste mode.
                            let announce = "printf '\\036" + marker + ":%s\\037' \"$$\"; exec "
                            try await outbound.write(ByteBuffer(string: announce + tmuxCommand + " attach-session -t " + SSHPrimitives.shellQuote(sessionID) + "\n"))
                            self.status = "Attaching…"
                        } else {
                            self.writer = outbound; self.connected = true; self.connecting = false; self.status = "Connected"
                            self.finishConnection(.success(()))
                        }
                        for try await output in inbound {
                            guard self.generation == attempt, !Task.isCancelled else { break }
                            switch output {
                            case .stdout(let buffer), .stderr(let buffer):
                                if let sessionID, attachmentCheck == nil, !self.connected {
                                    startup += String(decoding: buffer.readableBytesView, as: UTF8.self)
                                    if startup.utf8.count > 32_768 { startup = String(startup.suffix(8192)) }
                                    if let pid = TmuxSessions.announcedPID(in: startup, marker: marker) {
                                        attachmentCheck = Task {
                                            do {
                                                for _ in 0..<100 {
                                                    try Task.checkCancellation()
                                                    let clients = try await ssh.executeCommand(tmuxCommand + " list-clients -t " + SSHPrimitives.shellQuote(sessionID) + " -F '#{client_pid}:#{session_id}'", maxResponseSize: 8192)
                                                    if String(buffer: clients).split(separator: "\n").contains(Substring(pid + ":" + sessionID)) {
                                                        if let expectedInstance {
                                                            let actual = try await TmuxSessions.readInstance(using: ssh, id: sessionID, command: tmuxCommand)
                                                            guard actual == expectedInstance else { throw SessionReplaced() }
                                                        }
                                                        guard self.generation == attempt, !Task.isCancelled else { return }
                                                        self.attachedClientPID = pid
                                                        self.writer = outbound; self.connected = true; self.connecting = false; self.status = "Attached"
                                                        self.finishConnection(.success(()))
                                                        return
                                                    }
                                                    try await Task.sleep(nanoseconds: 50_000_000)
                                                }
                                                throw ConnectionFailure.timeout
                                            } catch {
                                                guard self.generation == attempt, !Task.isCancelled else { return }
                                                self.finishConnection(.failure(ConnectionFailure.attachment(error)))
                                                self.disconnect(); self.status = "Session unavailable"
                                                self.errorMessage = "The expected tmux session did not attach. Refresh sessions and reconnect."
                                            }
                                        }
                                    }
                                }
                                self.terminal.feed(byteArray: Array(buffer.readableBytesView)[...])
                                #if DEBUG
                                if self.nativeScrollFixture {
                                    let screen = self.terminal.getTerminal()
                                    let rendered = (0..<screen.rows).compactMap { screen.getLine(row:$0)?.translateToString(trimRight:true) }.joined(separator:"\n")
                                    let visibleNumbers = rendered.components(separatedBy:"HISTORY-").dropFirst().compactMap { Int($0.prefix(3)) }
                                    self.nativeScrollPosition = "\(visibleNumbers.min() ?? -1):\(visibleNumbers.count)"
                                    if visibleNumbers.contains(where:{$0 < 140}) { self.nativeScrollEvidence = "Older history rendered" }
                                    else if rendered.contains("HISTORY-179") { self.nativeScrollEvidence = "Live terminal rendered" }
                                    else { self.nativeScrollEvidence = "Other history rendered" }
                                }
                                #endif
                            }
                        }
                        completed = true
                    }
                } catch ChannelError.alreadyClosed { if !completed { throw ChannelError.alreadyClosed } }
                try? await ssh.close()
                if generation == attempt { connected = false; writer = nil; status = "Disconnected"; finishConnection(.failure(.network)) }
            } catch {
                guard generation == attempt, !Task.isCancelled else {
                    if let opened { try? await opened.close() }
                    return
                }
                // Invalidate the close callback before cleanup can report a
                // generic network error over the actual attachment failure.
                generation = UUID()
                connected = false; connecting = false; writer = nil; client = nil
                // NIO can surface channel closure before the validator error.
                // Preserve the actual verified rejection across that race.
                let reason = verification?.verificationError ?? error
                if let unknown = reason as? UnknownHost {
                    pendingProfile = target; unknownHost = unknown; status = "Verify host key"
                    finishConnection(.failure(.verificationRequired))
                } else if reason is ChangedHost {
                    finishConnection(.failure(.changedHost))
                    status = "Host key changed"
                    errorMessage = "Connection refused: this host’s SSH host key changed. Verify the change on the host before removing its saved trust."
                } else if (error is SSHClient.CommandFailed || error is TTYSTDError || error is SessionReplaced), sessionID != nil {
                    finishConnection(.failure(.sessionUnavailable))
                    status = "Session unavailable"
                    errorMessage = "This tmux session disappeared or could not be attached. Refresh this host’s session list."
                } else if error is AuthenticationFailed {
                    finishConnection(.failure(.authentication))
                    status = "Authentication failed"
                    errorMessage = "Add this device’s public key to the host’s ~/.ssh/authorized_keys, and check the username."
                } else if error is SecretStore.StorageError {
                    finishConnection(.failure(.protectedData))
                    status = "Unlock required"
                    errorMessage = "Unlock your phone to access its SSH key, then retry."
                } else {
                    finishConnection(.failure(.network))
                    status = "Connection failed"
                    errorMessage = "Could not open the SSH terminal. Check Tailscale, that the host is awake with SSH enabled, and its address and username."
                }
                if let opened { try? await opened.close() }
            }
            if generation == attempt { connecting = false }
        }
    }

    func acceptHostKey() throws {
        guard let candidate = unknownHost, let target = pendingProfile, target == profile else { throw ConnectionFailure.verificationRequired }
        try secrets.write(Data(candidate.key.utf8), account:target.trustID)
        unknownHost = nil; pendingProfile = nil
    }
    func trustHost() {
        do {
            try acceptHostKey()
            connect(sessionID: requestedSessionID, expectedInstance: requestedInstance, openShell: requestedShell, tmuxCommand: requestedTmuxCommand)
        } catch { errorMessage = "Could not save the verified host key." }
    }

    private func finishConnection(_ result: Result<Void,ConnectionFailure>) {
        let completion = connectionCompletion; connectionCompletion = nil
        completion?(result)
    }
    func connectAndWait(sessionID: String? = nil, expectedInstance: String? = nil,
                        openShell: Bool = true, tmuxCommand: String = TmuxSessions.command) async throws {
        let request = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
                connect(sessionID:sessionID,expectedInstance:expectedInstance,openShell:openShell,tmuxCommand:tmuxCommand,requestID:request) { result in
                    continuation.resume(with:result.mapError { $0 as Error })
                }
            }
        } onCancel: {
            Task { @MainActor in if self.generation == request { self.disconnect() } }
        }
    }
    func disconnect() {
        finishConnection(.failure(.cancelled))
        showLiveReturn = false; returningLive = false; attachedClientPID = nil
        terminal.dismissSelection()
        generation = UUID(); operation?.cancel(); operation = nil
        let old = client; client = nil; writer = nil
        connecting = false; connected = false; status = "Disconnected"; unknownHost = nil; pendingProfile = nil
        if let old { Task { try? await old.close() } }
    }

    func selectionRectangle(at point:CGPoint) async -> CGRect? {
        guard connected, let client, let id = requestedSessionID,
              let expected = requestedInstance, let pid = attachedClientPID else { return nil }
        let attempt = generation
        do {
            let actual = try await TmuxSessions.readInstance(using:client,id:id,command:requestedTmuxCommand)
            guard expected == actual else { throw SessionReplaced() }
            let clients = try await client.executeCommand(requestedTmuxCommand + " list-clients -t " + SSHPrimitives.shellQuote(id) + " -F '#{client_pid}|#{session_id}|#{window_offset_x}|#{window_offset_y}'",maxResponseSize:16384)
            let fields = String(buffer:clients).split(separator:"\n").map { $0.split(separator:"|",omittingEmptySubsequences:false).map(String.init) }
            guard let own = fields.first(where:{$0.count == 4 && $0[0] == pid && $0[1] == id}),
                  let offsetX = Int(own[2].isEmpty ? "0" : own[2]), let offsetY = Int(own[3].isEmpty ? "0" : own[3]), offsetX >= 0, offsetY >= 0 else { throw SessionReplaced() }
            let format = "#{pane_left}|#{pane_top}|#{pane_width}|#{pane_height}|#{pane_active}|#{window_zoomed_flag}|#{status-position}|#{status}"
            let output = try await client.executeCommand(requestedTmuxCommand + " list-panes -t " + SSHPrimitives.shellQuote(id) + " -F " + SSHPrimitives.shellQuote(format),maxResponseSize:16384)
            guard generation == attempt, connected else { return nil }
            let screen = terminal.getTerminal(), size = terminal.getOptimalFrameSize()
            let cell = CGSize(width:size.width/CGFloat(screen.cols),height:size.height/CGFloat(screen.rows))
            let grid = CGPoint(x:(point.x-terminal.contentOrigin.x)/cell.width,y:(point.y-terminal.contentOrigin.y)/cell.height)
            guard let pane = Self.paneRectangle(String(buffer:output),at:grid,cols:screen.cols,rows:screen.rows,offset:CGPoint(x:offsetX,y:offsetY)) else { throw SessionReplaced() }
            return CGRect(x:pane.minX*cell.width+terminal.contentOrigin.x,y:pane.minY*cell.height+terminal.contentOrigin.y,width:pane.width*cell.width,height:pane.height*cell.height)
        } catch {
            if generation == attempt { errorMessage = "Could not locate the touched tmux pane. Reconnect or try again after the layout settles." }
            return nil
        }
    }
    static func paneRectangle(_ metadata:String,at point:CGPoint,cols:Int,rows:Int,offset:CGPoint = .zero) -> CGRect? {
        let lines = metadata.split(separator:"\n")
        guard lines.count <= 128 else { return nil }
        for line in lines {
            let f = line.split(separator:"|",omittingEmptySubsequences:false).map(String.init)
            guard f.count == 8, ["0","1"].contains(f[4]), ["0","1"].contains(f[5]), ["top","bottom"].contains(f[6]) else { return nil }
            let numbers = f.prefix(4).compactMap(Int.init)
            guard numbers.count == 4, numbers.allSatisfy({ (0...10000).contains($0) }), numbers[2] > 0, numbers[3] > 0 else { return nil }
            let status = f[7] == "on" ? 1 : f[7] == "off" ? 0 : Int(f[7]) ?? -1
            guard (0...5).contains(status) else { return nil }
            if f[5] == "1" && f[4] != "1" { continue }
            let top = f[6] == "top" ? status : 0
            let rect = f[5] == "1" ? CGRect(x:0,y:top,width:cols,height:rows-status) : CGRect(x:CGFloat(numbers[0])-offset.x,y:CGFloat(numbers[1]+top)-offset.y,width:CGFloat(numbers[2]),height:CGFloat(numbers[3]))
            let clipped = rect.intersection(CGRect(x:0,y:top,width:cols,height:rows-status))
            if !clipped.isNull && clipped.contains(point) { return clipped }
        }
        return nil
    }

    /// Cancel copy mode only in this session's active pane. Never send an
    /// Escape/key to the program, or change another session after ID reuse.
    func returnToLive() async {
        terminal.stopMomentum(); terminal.dismissSelection()
        guard !returningLive, connected, let client,
              let id = requestedSessionID, TmuxSessions.validID(id),
              let instance = requestedInstance else { return }
        let parts = instance.split(separator: ":")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return }
        let attempt = generation, q = SSHPrimitives.shellQuote
        returningLive = true
        defer { if generation == attempt { returningLive = false } }
        let condition = "#{&&:#{==:#{pid},\(parts[0])},#{==:#{session_created},\(parts[1])}}"
        let operation = "if-shell -F -t \(q(id)) '#{==:#{pane_mode},copy-mode}' \(q("send-keys -X -t " + q(id) + " cancel")) ; display-message -p CHADMUX-LIVE-OK"
        do {
            let result = try await client.executeCommand(requestedTmuxCommand + " if-shell -F -t " + q(id) + " " + q(condition) + " " + q(operation) + " " + q("display-message -p CHADMUX-LIVE-STALE"), maxResponseSize:128)
            guard generation == attempt else { return }
            guard String(buffer:result).trimmingCharacters(in:.whitespacesAndNewlines) == "CHADMUX-LIVE-OK" else { throw SessionReplaced() }
            showLiveReturn = false
        } catch {
            if generation == attempt { errorMessage = "Could not leave tmux history. Check the connection and try again." }
        }
    }

    /// Asks tmux to redraw this phone or desktop client (after a local clear).
    func redrawClient() async {
        guard connected, let client, let pid = attachedClientPID, let id = requestedSessionID else { return }
        let listing = try? await client.executeCommand(requestedTmuxCommand + " list-clients -t " + SSHPrimitives.shellQuote(id) + " -F '#{client_pid} #{client_name}'", maxResponseSize: 8192)
        guard let name = listing.flatMap({ String(buffer: $0).split(separator: "\n").map(String.init).first { $0.hasPrefix(pid + " ") } })?.dropFirst(pid.count + 1),
              !name.isEmpty else { return }
        _ = try? await client.executeCommand(requestedTmuxCommand + " refresh-client -t " + SSHPrimitives.shellQuote(String(name)), maxResponseSize: 1024)
    }

    func pinnedUploadSettings() throws -> SSHClientSettings {
        guard connected else { throw NotConnected() }
        do { return try Self.pinnedSettings(for: profile, secrets: secrets) }
        catch is NotTrusted { throw NotConnected() }
    }

    /// Settings for an extra connection to an already-verified host. It never
    /// offers a new host key for trust: an unpinned host is refused.
    static func pinnedSettings(for target: MacConnection, secrets: SecretStore) throws -> SSHClientSettings {
        guard let saved = try secrets.read(target.trustID), let pin = String(data: saved, encoding: .utf8) else { throw NotTrusted() }
        let privateKey = try secrets.deviceKey()
        var settings = SSHClientSettings(host: target.host, port: target.port,
            authenticationMethod: { .ed25519(username: target.username, privateKey: privateKey) },
            hostKeyValidator: .custom(PinnedHostValidator(expected: pin)))
        settings.connectTimeout = .seconds(15)
        return settings
    }

    func sendBytes(_ bytes: [UInt8]) async throws {
        guard let writer, connected else { throw NotConnected() }
        let attempt = generation
        do { try await writer.write(ByteBuffer(bytes: bytes)) }
        catch {
            guard generation == attempt else { throw error }
            errorMessage = "Connection interrupted. Input delivery is uncertain; inspect the terminal before retrying."
            disconnect()
            throw error
        }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard let writer else { return }
        let attempt = generation
        Task {
            do { try await writer.changeSize(cols: max(1,newCols), rows: max(1,newRows), pixelWidth: 0, pixelHeight: 0) }
            catch { if self.connected && self.generation == attempt { self.errorMessage = "Terminal resize failed. Reconnect to restore the correct size." } }
        }
    }
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data), attempt = generation
        Task {
            guard generation == attempt else { return }
            try? await sendBytes(bytes)
        }
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    #if os(macOS)
    /// tmux's copy (OSC 52) reaches the Mac clipboard; without this it was dropped.
    func clipboardCopy(source: TerminalView, content: Data) { (source as? MacNativeTerminalView)?.copyFromHost(content) }
    #endif
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    struct SessionReplaced: Error {}
    struct InvalidConnection: Error {}
    struct NotConnected: Error {}
    struct NotTrusted: Error {}
}
