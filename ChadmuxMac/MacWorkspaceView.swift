import SwiftUI
import AppKit

/// Tabs across every host, in host order: what the tab strip, Cmd-1…8 and
/// Close Tab act on.
@MainActor
enum MacTabs {
    struct Entry: Identifiable {
        let host: HostProfile
        let workspace: SessionWorkspace
        let tab: SessionTab
        var id: String { host.id.uuidString + "/" + tab.id }
    }
    static func all(_ model: HostsModel) -> [Entry] {
        model.orderedWorkspaces.flatMap { entry in entry.workspace.tabs.map { Entry(host: entry.host, workspace: entry.workspace, tab: $0) } }
    }
    static func selected(_ model: HostsModel) -> Entry? {
        guard let id = model.selectedHostID, let workspace = model.workspace(for: id), let tab = workspace.selected, let host = model.host(id) else { return nil }
        return Entry(host: host, workspace: workspace, tab: tab)
    }
    /// Cmd-1…8: the nth open tab across hosts (1-based), if there is one.
    static func select(number: Int, in model: HostsModel) {
        let tabs = all(model)
        guard (1...tabs.count).contains(number) else { return }
        let entry = tabs[number - 1]
        model.select(entry.tab.session, on: entry.host.id)
    }
    /// Ctrl-Cmd-[ / ]: the previous or next open tab across hosts, wrapping.
    static func cycle(by step: Int, in model: HostsModel) {
        let tabs = all(model)
        guard !tabs.isEmpty else { return }
        let current = selected(model).flatMap { now in tabs.firstIndex { $0.id == now.id } } ?? (step > 0 ? -1 : 0)
        let entry = tabs[((current + step) % tabs.count + tabs.count) % tabs.count]
        model.select(entry.tab.session, on: entry.host.id)
    }
    /// Closing loses nothing silently: a tab with a draft, images, a pending
    /// transcript or live dictation asks first.
    /// The Mac has no input bar, so a tab holds no draft, images or dictation of
    /// its own (anything an older version saved is no longer shown): closing a
    /// tab never loses work and needs no confirmation. Kept as the one place that
    /// decides, for the confirmation dialog the window still hosts.
    static func needsConfirmation(_ entry: Entry) -> Bool { false }
    /// Where Cmd-T creates: the host on screen if connected, else the first connected host.
    static func newSessionHost(_ model: HostsModel) -> UUID? {
        if let id = model.selectedHostID, model.workspace(for: id)?.connection.connected == true { return id }
        return model.orderedWorkspaces.first { $0.workspace.connection.connected }?.host.id
    }
}

/// Window-level requests from menus and shortcuts (they can't present sheets).
@MainActor
final class MacWindowActions: ObservableObject {
    @Published var creatingOn: UUID?
    @Published var closing: MacTabs.Entry?
    @Published var renaming: RenameTarget?
    /// The Mac's own sidebar state (shown by default), remembered across launches.
    @Published var sidebarVisible: Bool { didSet { preferences.set(sidebarVisible, forKey: Self.sidebarKey) } }
    static let sidebarKey = "mac.sidebarVisible"
    let model: HostsModel
    private let preferences: UserDefaults
    init(model: HostsModel, preferences: UserDefaults = .standard) {
        self.model = model; self.preferences = preferences
        sidebarVisible = preferences.object(forKey: Self.sidebarKey) as? Bool ?? true
        TerminalDictation.install(on: model.voice)
    }
    func toggleSidebar() { sidebarVisible.toggle() }
    /// The mic and ⇧⌘D: start dictating into the tab on screen (or `entry`), or
    /// stop the recording in progress, whichever tab it belongs to, and paste it there.
    func toggleDictation(_ entry: MacTabs.Entry? = nil) {
        let voice = model.voice
        if voice.active {
            if voice.phase == .recording { voice.stop() }
            return
        }
        guard let entry = entry ?? MacTabs.selected(model) else { return }
        guard entry.tab.transport.connected else {
            entry.tab.dictationStatus = "Connect to \(entry.host.label) before dictating."; return
        }
        voice.start(tab: entry.tab)
    }
    /// × or Esc: discard the recording or transcription; nothing is pasted.
    func cancelDictation() {
        if model.voice.active { model.voice.cancel(message: TerminalDictation.cancelled) }
    }
    /// Sessions > Rename Session…: the tab on screen.
    func renameSelected() {
        guard let entry = MacTabs.selected(model),
              entry.workspace.sessions.contains(where: { $0.id == entry.tab.session.id && $0.instance == entry.tab.session.instance }) else { return }
        renaming = RenameTarget(session: entry.tab.session, host: entry.host.id)
    }
    /// Falls back to the host on screen, whose sheet then says to connect first.
    func newSession() { creatingOn = MacTabs.newSessionHost(model) ?? model.selectedHostID }
    func closeSelectedTab() {
        guard let entry = MacTabs.selected(model) else { return }
        if MacTabs.needsConfirmation(entry) { closing = entry } else { entry.workspace.close(entry.tab.id) }
    }
}

extension FocusedValues {
    @Entry var windowActions: MacWindowActions?
}

/// Flat, dark panels in the terminal's family (cmux-like): no boxes, thin rules.
enum MacTheme {
    static let terminal = Color(red: 0.071, green: 0.075, blue: 0.086)
    static let terminalNS = NSColor(srgbRed: 0.071, green: 0.075, blue: 0.086, alpha: 1)
    static let sidebar = Color(red: 0.094, green: 0.098, blue: 0.114)
    static let panel = Color(red: 0.086, green: 0.090, blue: 0.105)
    static let rule = Color.white.opacity(0.07)
    static let hover = Color.white.opacity(0.05)
    static let selection = Color.white.opacity(0.10)
    static let primary = Color.white.opacity(0.90)
    static let secondary = Color.white.opacity(0.50)
    static let tertiary = Color.white.opacity(0.30)
    static let live = Color(red: 0.36, green: 0.80, blue: 0.52)
    static let busy = Color.orange
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.40)
    /// The top rows share the hidden title bar's line with the window buttons.
    static let barHeight: CGFloat = 30
}

/// A quiet icon button: no bezel, brightening on hover.
struct QuietIconButton: View {
    let systemImage: String
    let label: String
    var tint: Color = MacTheme.secondary
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: 12, weight: .medium))
                .foregroundStyle(enabled ? (hovering ? MacTheme.primary : tint) : MacTheme.tertiary.opacity(0.6))
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovering && enabled ? MacTheme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(label).accessibilityLabel(label)
        .onHover { hovering = $0 }
    }
}

struct MacWorkspaceView: View {
    @ObservedObject var model: HostsModel
    @StateObject private var actions: MacWindowActions
    @State private var ending: (session: RemoteSession, host: UUID)?
    @Environment(\.scenePhase) private var scenePhase
    init(model: HostsModel) {
        self.model = model
        _actions = StateObject(wrappedValue: MacWindowActions(model: model))
    }
    var body: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { actions.sidebarVisible ? .all : .detailOnly },
            set: { actions.sidebarVisible = $0 != .detailOnly })) {
            MacSidebar(model: model, actions: actions, ending: $ending)
                .ignoresSafeArea(.container, edges: .top)
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 380)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail.ignoresSafeArea(.container, edges: .top)
        }
        .background(MacTheme.terminal)
        .preferredColorScheme(.dark)
        .focusedSceneValue(\.windowActions, actions)
        .focusedSceneObject(actions)
        .sheet(isPresented: Binding(get: { actions.creatingOn != nil }, set: { if !$0 { actions.creatingOn = nil } })) {
            if let id = actions.creatingOn, let target = model.workspace(for: id) {
                NewSessionSheet(workspace: target, host: target.hostLabel) { model.selectedHostID = id }
                    .formStyle(.grouped)
                    .frame(width: 480, height: 440)
            }
        }
        .sheet(item: $actions.renaming) { target in
            if let workspace = model.workspace(for: target.host) {
                RenameSessionSheet(workspace: workspace, session: target.session, host: workspace.hostLabel)
                    .formStyle(.grouped)
                    .frame(width: 460, height: 300)
            }
        }
        .alert("End “\(ending?.session.name ?? "")”?", isPresented: Binding(get: { ending != nil }, set: { if !$0 { ending = nil } }), presenting: ending) { target in
            Button("Cancel", role: .cancel) { ending = nil }
            Button("End session", role: .destructive) {
                ending = nil
                Task { await model.workspace(for: target.host)?.endSession(target.session) }
            }
        } message: { target in
            Text("This ends everything running in “\(target.session.name)” on \(model.host(target.host)?.label ?? "this host"), including any Claude conversation in it. It can’t be undone.")
        }
        .alert("Verify \(model.verifying?.host.label ?? "the host")’s host key", isPresented: Binding(get: { model.verifying != nil }, set: { _ in })) {
            Button("Cancel", role: .cancel) { model.verifying?.workspace.cancelHostVerification() }
            Button("Trust verified key") { model.verifying?.workspace.trustResumeHost() }
        } message: {
            Text("Compare this fingerprint with \(model.verifying?.host.label ?? "the host")’s SSH host key before trusting it:\n\n" + (model.verifying?.workspace.verificationTransport?.unknownHost?.fingerprint ?? ""))
        }
        .confirmationDialog("Close this tab and discard its unsent draft?", isPresented: Binding(get: { actions.closing != nil }, set: { if !$0 { actions.closing = nil } })) {
            Button("Discard draft and close", role: .destructive) {
                if let entry = actions.closing { entry.workspace.close(entry.tab.id) }
                actions.closing = nil
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in if phase == .active { model.becameActive() } }
    }

    @ViewBuilder private var detail: some View {
        VStack(spacing: 0) {
            if let entry = MacTabs.selected(model) {
                MacSessionView(tab: entry.tab, transport: entry.tab.transport, host: entry.host, workspace: entry.workspace, actions: actions, voice: model.voice).id(entry.id)
            } else {
                MacEmptyState(model: model, actions: actions)
                    .overlay(alignment: .topLeading) { MacSidebarReveal(actions: actions).frame(height: MacTheme.barHeight) }
            }
            if let workspace = model.selectedWorkspace, let message = workspace.recoveryError ?? workspace.error ?? workspace.connection.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(MacTheme.danger)
                    Text(message).foregroundStyle(MacTheme.primary).accessibilityIdentifier("connection.error")
                    Spacer(minLength: 0)
                }
                .font(.callout).padding(.horizontal, 14).padding(.vertical, 8)
                .background(MacTheme.danger.opacity(0.12))
                .overlay(alignment: .top) { MacTheme.rule.frame(height: 1) }
            }
        }
        .background(MacTheme.terminal)
    }
}

/// Nothing open yet: say what to do, quietly.
struct MacEmptyState: View {
    @ObservedObject var model: HostsModel
    @ObservedObject var actions: MacWindowActions
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "terminal").font(.system(size: 30, weight: .light)).foregroundStyle(MacTheme.tertiary)
            Text(model.hosts.isEmpty ? "Add a host to begin" : "Open a session").font(.title3).foregroundStyle(MacTheme.primary)
            Text(model.hosts.isEmpty ? "Add this Mac or a server on your tailnet in Host Settings."
                 : "Choose a session in the sidebar, or start a new Claude session.")
                .font(.callout).foregroundStyle(MacTheme.secondary).multilineTextAlignment(.center)
            if model.hosts.isEmpty {
                Button("Host Settings…") { openSettings() }.buttonStyle(.link)
            } else {
                Button("New Claude Session  ⌘T") { actions.newSession() }.buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// cmux-style vertical tabs: hosts, their sessions, and which are open.
struct MacSidebar: View {
    @ObservedObject var model: HostsModel
    @ObservedObject var actions: MacWindowActions
    @Binding var ending: (session: RemoteSession, host: UUID)?
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        VStack(spacing: 0) {
            // The window's close/minimize/zoom buttons sit at the left of this row.
            HStack(spacing: 2) {
                Spacer().frame(width: 70)
                QuietIconButton(systemImage: "sidebar.left", label: "Hide sidebar") { actions.toggleSidebar() }
                    .accessibilityIdentifier("sidebar.toggle")
                Spacer()
                QuietIconButton(systemImage: "plus", label: "New Claude session") { actions.newSession() }
                QuietIconButton(systemImage: "gearshape", label: "Host settings") { openSettings() }
            }
            .padding(.horizontal, 10).frame(height: MacTheme.barHeight)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.orderedWorkspaces, id: \.host.id) { entry in
                        MacHostSection(model: model, host: entry.host, workspace: entry.workspace, connection: entry.workspace.connection,
                                       actions: actions, ending: $ending)
                    }
                    if model.hosts.isEmpty {
                        Button("Add a host…") { openSettings() }.buttonStyle(.link).padding(.horizontal, 14)
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.never)
        }
        .background(MacTheme.sidebar)
        .overlay(alignment: .trailing) { MacTheme.rule.frame(width: 1) }
    }
}

struct MacHostSection: View {
    @ObservedObject var model: HostsModel
    let host: HostProfile
    @ObservedObject var workspace: SessionWorkspace
    @ObservedObject var connection: MacTransport
    @ObservedObject var actions: MacWindowActions
    @Binding var ending: (session: RemoteSession, host: UUID)?
    @State private var hovering = false
    private var busy: Bool { [.reconnecting, .discovering, .attaching].contains(workspace.resumeState) }
    private var status: String {
        busy ? workspace.resumeState.rawValue : connection.connected ? "Connected" : workspace.resumeState == .unavailable ? "Offline" : connection.status
    }
    private var onScreen: Bool { model.selectedHostID == host.id }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Circle().fill(connection.connected ? MacTheme.live : busy ? MacTheme.busy : MacTheme.tertiary).frame(width: 7, height: 7)
                Text(host.label.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(MacTheme.secondary).lineLimit(1)
                Text(status).font(.system(size: 11)).foregroundStyle(MacTheme.tertiary).lineLimit(1)
                    .accessibilityLabel(host.label + " status: " + status)
                Spacer(minLength: 2)
                if !connection.connected && !busy && host.connection.isValid {
                    Button("Connect") { workspace.retryConnection() }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Connect to " + host.label)
                }
                QuietIconButton(systemImage: "arrow.clockwise", label: "Refresh " + host.label + " sessions") { Task { await workspace.refresh() } }
                    .disabled(!connection.connected || workspace.refreshing)
                QuietIconButton(systemImage: "plus", label: "New Claude session on " + host.label) { actions.creatingOn = host.id }
                    .disabled(!connection.connected)
            }
            .padding(.horizontal, 12).frame(height: 26)
            .contextMenu {
                if connection.connected || busy { Button("Disconnect") { workspace.disconnect() } }
                else { Button("Connect") { workspace.retryConnection() }.disabled(!host.connection.isValid) }
                Button("Refresh Sessions") { Task { await workspace.refresh() } }.disabled(!connection.connected)
                Button("New Claude Session…") { actions.creatingOn = host.id }.disabled(!connection.connected)
            }
            // The on-screen host's errors show under the terminal; others show here.
            if !onScreen, let message = workspace.recoveryError ?? workspace.error {
                Text(message).font(.system(size: 11)).foregroundStyle(MacTheme.danger).padding(.horizontal, 14).padding(.bottom, 2)
                    .accessibilityLabel(host.label + " error: " + message)
            }
            ForEach(workspace.sidebarSessions) { session in
                MacSessionRow(model: model, host: host, workspace: workspace, connection: connection, session: session,
                              context: workspace.sessionContext[session.id], actions: actions) { ending = (session, host.id) }
            }
            if workspace.sidebarSessions.isEmpty {
                Text(connection.connected ? "No sessions yet. Press + to start one." : "Connect to see its sessions.")
                    .font(.system(size: 11)).foregroundStyle(MacTheme.tertiary).padding(.horizontal, 14).padding(.vertical, 4)
            }
        }
    }
}

/// One session: name over its folder and activity. Open tabs carry a dot and a
/// close button; the selected tab is highlighted. Ending is always confirmed.
struct MacSessionRow: View {
    @ObservedObject var model: HostsModel
    let host: HostProfile
    @ObservedObject var workspace: SessionWorkspace
    @ObservedObject var connection: MacTransport
    let session: RemoteSession
    let context: TmuxSessions.Context?
    @ObservedObject var actions: MacWindowActions
    let end: () -> Void
    @State private var hovering = false
    private var tab: SessionTab? { workspace.tabs.first { $0.id == session.id } }
    private var selected: Bool { model.selectedHostID == host.id && workspace.selectedID == session.id }
    private var live: Bool { workspace.sessions.contains { $0.id == session.id && $0.instance == session.instance } }
    private var detail: String {
        var parts: [String] = []
        if let context {
            let path = TmuxSessions.displayPath(context.path, user: host.connection.username)
            if path != "~" { parts.append(path) }
            if context.clients > 1 || (context.clients == 1 && tab?.transport.connected != true) { parts.append("\(context.clients) attached") }
        }
        if !live { parts.append("ended") }
        return parts.joined(separator: " · ")
    }
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(tab == nil ? Color.clear : selected ? Color.accentColor : MacTheme.secondary)
                .frame(width: 6, height: 6)
            Button { model.select(session, on: host.id) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.name).font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(live ? MacTheme.primary : MacTheme.secondary).lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail).font(.system(size: 11)).foregroundStyle(MacTheme.tertiary).lineLimit(1).truncationMode(.head)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("session." + host.label + "." + session.id)
            .accessibilityLabel(session.name)
            .accessibilityValue(tab == nil ? "" : selected ? "Open, selected" : "Open")
            HStack(spacing: 0) {
                if live {
                    QuietIconButton(systemImage: "pencil", label: "Rename session " + session.name + " on " + host.label) {
                        actions.renaming = RenameTarget(session: session, host: host.id)
                    }
                    .disabled(!connection.connected || workspace.renamingSessionID != nil)
                    if workspace.endingSessionID == session.id { ProgressView().controlSize(.mini).frame(width: 22) }
                    else {
                        QuietIconButton(systemImage: "minus.circle", label: "End session " + session.name + " on " + host.label, tint: MacTheme.danger.opacity(0.8), action: end)
                            .disabled(!connection.connected || workspace.endingSessionID != nil)
                    }
                }
                if let tab {
                    QuietIconButton(systemImage: "xmark", label: "Close tab " + session.name + " on " + host.label) {
                        let entry = MacTabs.Entry(host: host, workspace: workspace, tab: tab)
                        if MacTabs.needsConfirmation(entry) { actions.closing = entry } else { workspace.close(tab.id) }
                    }
                }
            }
            // Shown on hover or selection. Not quite 0: SwiftUI drops fully transparent
            // views from the accessibility tree, and VoiceOver must still reach them.
            .opacity(hovering || selected ? 1 : 0.001)
        }
        .padding(.leading, 8).padding(.trailing, 6).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? MacTheme.selection : hovering ? MacTheme.hover : .clear))
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(tab == nil ? "Open" : "Show") { model.select(session, on: host.id) }
            if let tab {
                Button("Close Tab") {
                    let entry = MacTabs.Entry(host: host, workspace: workspace, tab: tab)
                    if MacTabs.needsConfirmation(entry) { actions.closing = entry } else { workspace.close(tab.id) }
                }
            }
            if live {
                Button("Rename…") { actions.renaming = RenameTarget(session: session, host: host.id) }
                    .disabled(!connection.connected)
                Divider()
                Button("End Session…", role: .destructive, action: end).disabled(!connection.connected)
            }
        }
    }
}

/// One tab: a slim header over the full-bleed terminal. There is no input bar on
/// the Mac: you type into Claude directly, and images dropped or ⌘V-pasted onto
/// the terminal are uploaded to the session's host and their paths pasted.
/// Dictation (the mic beside "Live") pastes its transcript the same way.
struct MacSessionView: View {
    @ObservedObject var tab: SessionTab
    @ObservedObject var transport: MacTransport
    let host: HostProfile
    @ObservedObject var workspace: SessionWorkspace
    @ObservedObject var actions: MacWindowActions
    let voice: VoiceCoordinator
    @StateObject private var drop: TerminalImageDrop
    @State private var dropTargeted = false
    @State private var pasteMonitor: Any?

    init(tab: SessionTab, transport: MacTransport, host: HostProfile, workspace: SessionWorkspace, actions: MacWindowActions, voice: VoiceCoordinator) {
        self.tab = tab; self.transport = transport; self.host = host; self.workspace = workspace; self.actions = actions; self.voice = voice
        let media = tab.media, root = workspace.uploadRoot
        _drop = StateObject(wrappedValue: TerminalImageDrop(media: media,
            upload: { [transport] attachments in
                try await PhotoUpload.upload(attachments, store: media, settings: try transport.pinnedUploadSettings(), root: root)
            },
            write: { [transport] bytes in try await transport.sendBytes(bytes) },
            ready: { [transport] in transport.connected },
            bracketed: { [transport] in transport.terminal.getTerminal().bracketedPasteMode }))
    }

    var body: some View {
        VStack(spacing: 0) {
            MacSessionHeader(tab: tab, transport: transport, host: host, workspace: workspace, connection: workspace.connection, actions: actions, drop: drop)
            if transport.connected {
                MacTerminalSurface(transport: transport)
                    .padding(.leading, 8).padding(.top, 4)
                    .background(MacTheme.terminal)
                    .focusedSceneValue(\.terminalTransport, transport)
                    .accessibilityIdentifier("terminal.surface")
                    .overlay(alignment: .bottomTrailing) {
                        HStack(spacing: 8) {
                            if transport.showLiveReturn {
                                Button { Task { await transport.returnToLive() } } label: {
                                    Label("Live", systemImage: "arrow.down.to.line").font(.system(size: 11, weight: .medium))
                                        .padding(.horizontal, 10).padding(.vertical, 5)
                                        .background(Capsule().fill(MacTheme.panel)).overlay(Capsule().stroke(MacTheme.rule))
                                }
                                .buttonStyle(.plain).foregroundStyle(MacTheme.primary)
                                .help("Return to live output (⌥⌘↓)").accessibilityLabel("Return to Live")
                                .disabled(transport.returningLive)
                            }
                            MacDictationControl(voice: voice, tab: tab,
                                                toggle: { actions.toggleDictation(MacTabs.Entry(host: host, workspace: workspace, tab: tab)) },
                                                cancel: { actions.cancelDictation() })
                        }
                        .padding(12)
                    }
                    // Images dropped on the terminal are uploaded and their paths pasted.
                    .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
                        Task {
                            let dropped = await MacImageImport.dropped(from: providers)
                            await drop.add(dropped.images, skipped: dropped.skipped, host: host.label)
                        }
                        return true
                    }
                    .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 2).padding(2).allowsHitTesting(false) } }
                    .onAppear { DispatchQueue.main.async { transport.terminal.window?.makeFirstResponder(transport.terminal) } }
                if let error = transport.errorMessage {
                    Text(error).font(.callout).foregroundStyle(MacTheme.danger).padding(.horizontal, 14).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "bolt.horizontal.circle").font(.system(size: 26, weight: .light)).foregroundStyle(MacTheme.tertiary)
                    Text(transport.status).font(.title3).foregroundStyle(MacTheme.primary)
                    Text(transport.errorMessage ?? "The tmux session keeps running while this Mac is disconnected.")
                        .font(.callout).foregroundStyle(MacTheme.secondary).multilineTextAlignment(.center)
                }
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(MacTheme.terminal)
        .onAppear(perform: watchPaste)
        .onDisappear { if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }; pasteMonitor = nil }
    }

    /// ⌘V in the terminal with an image on the clipboard uploads it; any other
    /// paste (text) is left to the terminal. Esc while this tab is dictating
    /// discards the recording instead of reaching the session.
    private func watchPaste() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [transport, drop, host, voice, tab, actions] event in
            if event.keyCode == 53, voice.active, voice.origin === tab,
               event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
               event.window === transport.terminal.window, event.window?.attachedSheet == nil {
                actions.cancelDictation()
                return nil
            }
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v",
                  event.window?.firstResponder === transport.terminal else { return event }
            let pasted = MacImageImport.pasted(on: MacImageImport.pasteboard)
            guard !pasted.images.isEmpty || pasted.skipped > 0 else { return event }
            Task { await drop.add(pasted.images, skipped: pasted.skipped, host: host.label) }
            return nil
        }
    }
}

/// With the sidebar hidden: room for the window buttons, then a button to bring it back.
struct MacSidebarReveal: View {
    @ObservedObject var actions: MacWindowActions
    var body: some View {
        if !actions.sidebarVisible {
            HStack(spacing: 0) {
                Spacer().frame(width: 78)
                QuietIconButton(systemImage: "sidebar.left", label: "Show sidebar") { actions.toggleSidebar() }
                    .accessibilityIdentifier("sidebar.toggle")
            }
        }
    }
}

/// The session's name, host and folder once, with its host's connection state.
struct MacSessionHeader: View {
    @ObservedObject var tab: SessionTab
    @ObservedObject var transport: MacTransport
    let host: HostProfile
    @ObservedObject var workspace: SessionWorkspace
    @ObservedObject var connection: MacTransport
    @ObservedObject var actions: MacWindowActions
    @ObservedObject var drop: TerminalImageDrop
    private var busy: Bool { [.reconnecting, .discovering, .attaching].contains(workspace.resumeState) }
    private var dropStatus: (text: String, error: Bool)? {
        switch drop.state {
        case .idle: return nil
        case .uploading(let count): return ("Uploading \(count == 1 ? "image" : "\(count) images")…", false)
        case .added(let count, let skipped):
            let added = "Added \(count == 1 ? "image" : "\(count) images") to the prompt"
            return (skipped == 0 ? added : added + " · skipped \(skipped) (not an image or over 32 MiB)", skipped > 0)
        case .failed(let message): return (message, true)
        }
    }
    var body: some View {
        HStack(spacing: 8) {
            MacSidebarReveal(actions: actions)
            Text(tab.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(MacTheme.primary).lineLimit(1)
            Text(host.label).font(.system(size: 12)).foregroundStyle(MacTheme.secondary).accessibilityIdentifier("session.host")
            if let path = workspace.sessionContext[tab.id]?.path {
                Text(TmuxSessions.displayPath(path, user: host.connection.username))
                    .font(.system(size: 12)).foregroundStyle(MacTheme.tertiary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            if let status = tab.dictationStatus {
                Text(status).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(TerminalDictation.isError(status) ? MacTheme.danger : MacTheme.secondary)
                    .help(status)
                    .accessibilityIdentifier("terminal.dictationStatus")
                    .task(id: status) {
                        // Like the upload status: it clears itself, errors a little later.
                        try? await Task.sleep(nanoseconds: TerminalDictation.isError(status) ? 10_000_000_000 : 5_000_000_000)
                        if !Task.isCancelled, tab.dictationStatus == status { tab.dictationStatus = nil }
                    }
            }
            if let dropStatus {
                if !dropStatus.error, drop.busy { ProgressView().controlSize(.mini) }
                Text(dropStatus.text).font(.system(size: 11)).lineLimit(1)
                    .foregroundStyle(dropStatus.error ? MacTheme.danger : MacTheme.secondary)
                    .accessibilityIdentifier("terminal.dropStatus")
            }
            #if DEBUG
            if !workspace.fixtureEvidence.isEmpty {
                Text(workspace.fixtureEvidence).font(.system(size: 10)).foregroundStyle(MacTheme.tertiary).lineLimit(1)
                    .accessibilityIdentifier("manage.fixture.evidence")
            }
            #endif
            if busy {
                ProgressView().controlSize(.mini)
                Text(workspace.resumeState.rawValue).font(.system(size: 11)).foregroundStyle(MacTheme.secondary)
            } else if !transport.connected && connection.profile.isValid {
                Button(workspace.resumeDesired || workspace.resumeState == .unavailable ? "Retry" : "Connect") { workspace.retryConnection() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("connection.connect")
            }
            Circle().fill(transport.connected ? MacTheme.live : busy ? MacTheme.busy : MacTheme.tertiary).frame(width: 7, height: 7)
                .help(transport.connected ? "Connected" : transport.status)
                .accessibilityElement().accessibilityLabel("Connection")
                .accessibilityIdentifier("connection.status").accessibilityValue(transport.connected ? "Connected" : transport.status)
        }
        .padding(.leading, actions.sidebarVisible ? 14 : 0).padding(.trailing, 12).frame(height: MacTheme.barHeight)
        .background(MacTheme.panel)
        .overlay(alignment: .bottom) { MacTheme.rule.frame(height: 1) }
    }
}

/// The Sessions menu mirrors the sidebar; tab shortcuts follow terminal apps.
struct SessionCommands: Commands {
    // An observed object, so titles like Show/Hide Sidebar follow the window's state.
    @FocusedObject private var actions: MacWindowActions?
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Claude Session…") { actions?.newSession() }
                .keyboardShortcut("t", modifiers: .command)
                // Enabled with the window: menus don't observe host connection state.
                .disabled(actions == nil)
        }
        CommandGroup(before: .saveItem) {
            Button("Close Tab") { actions?.closeSelectedTab() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(actions == nil)
        }
        CommandGroup(replacing: .sidebar) {
            Button(actions?.sidebarVisible == false ? "Show Sidebar" : "Hide Sidebar") { actions?.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.control, .command])
                .disabled(actions == nil)
        }
        CommandMenu("Sessions") {
            Button("Rename Session…") { actions?.renameSelected() }
                .disabled(actions.map { MacTabs.selected($0.model) == nil } ?? true)
            Button("Refresh All Hosts") {
                guard let model = actions?.model else { return }
                for (_, workspace) in model.orderedWorkspaces { Task { await workspace.refresh() } }
            }
            .keyboardShortcut("r", modifiers: .command)
            Divider()
            Button("Previous Tab") { if let model = actions?.model { MacTabs.cycle(by: -1, in: model) } }
                .keyboardShortcut("[", modifiers: [.control, .command])
            Button("Next Tab") { if let model = actions?.model { MacTabs.cycle(by: 1, in: model) } }
                .keyboardShortcut("]", modifiers: [.control, .command])
            Divider()
            ForEach(1...8, id: \.self) { number in
                Button("Show Tab \(number)") { if let model = actions?.model { MacTabs.select(number: number, in: model) } }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
            }
        }
    }
}
