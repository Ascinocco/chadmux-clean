import SwiftUI
import AVFAudio

struct ContentView: View {
    @StateObject private var model: HostsModel
    init() {
        #if DEBUG
        if let fixture = ViewFixtures.model() {
            _model = StateObject(wrappedValue: fixture)
            return
        }
        #endif
        _model = StateObject(wrappedValue: HostsModel(preferences: MacTransport.appPreferences(), recovery: RecoveryStore()))
    }
    var body: some View { HostsRoot(model: model).environmentObject(model.voice) }
}

/// App lifecycle for every host, host settings, and the selected host's screen.
struct HostsRoot: View {
    @ObservedObject var model: HostsModel
    @State private var settings = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Group {
            if let workspace = model.selectedWorkspace {
                WorkspaceScreen(model: model, workspace: workspace, connection: workspace.connection, settings: $settings)
                    .id(model.selectedHostID)
            } else {
                NavigationStack {
                    ContentUnavailableView {
                        Label("Add a host", systemImage: "desktopcomputer")
                    } description: {
                        Text("Chadmux reaches your Mac or Linux hosts over Tailscale with SSH public-key authentication.")
                    } actions: { Button("Connection settings") { settings = true } }
                    .navigationTitle("Chadmux").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { settings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Connection settings")
                        }
                    }
                }.tint(.green)
            }
        }
        .sheet(isPresented: $settings) { HostsSettings(model: model) { settings = false } }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active { model.becameActive() }
            if phase == .background {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                model.background()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
            if scenePhase == .active { model.becameActive() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { _ in
            model.voice.cancel(message: "Audio was interrupted. Your draft is retained; record again when ready.")
        }
    }
}

/// The selected host's terminal, with every host's sessions in one sidebar.
struct WorkspaceScreen: View {
    @ObservedObject var model: HostsModel
    @ObservedObject var workspace: SessionWorkspace
    @ObservedObject var connection: MacTransport
    @Binding var settings: Bool
    @State private var closing: (tab: String, host: UUID)?
    @State private var creatingOn: UUID?
    @State private var ending: (session: RemoteSession, host: UUID)?
    @State private var renaming: RenameTarget?
    var body: some View {
        NavigationStack {
            presentations(content
                .navigationTitle(workspace.selected?.name ?? "Chadmux")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarItems })
        }.tint(.green)
    }
    private var content: some View {
        VStack(spacing: 0) {
            WorkspaceConnectionBar(workspace:workspace, connection:connection,
                terminal:workspace.selected?.transport ?? connection)
                .dismissSidebarOnTap($model.sidebarExpanded)
            VoiceActivity(voice: workspace.voice)
                .dismissSidebarOnTap($model.sidebarExpanded)
            HStack(spacing: 0) {
                if model.sidebarExpanded { sessionSidebar.frame(width: 190).background(.quaternary) }
                Group {
                    if let tab = workspace.selected { SessionTerminal(tab: tab, transport: tab.transport).id(tab.id) }
                    else if connection.connected {
                        ContentUnavailableView("Select a tmux session", systemImage: "rectangle.split.2x1", description: Text("Open the left sidebar to choose a running session on " + workspace.hostLabel + "."))
                    } else {
                        ContentUnavailableView {
                            Label("Connect to " + workspace.hostLabel, systemImage: "terminal")
                        } description: {
                            Text("Chadmux reaches this host over Tailscale with SSH public-key authentication.")
                        } actions: { Button("Connection settings") { settings = true } }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .dismissSidebarOnTap($model.sidebarExpanded)
            }
            #if DEBUG
            if !workspace.fixtureEvidence.isEmpty {
                Text(workspace.fixtureEvidence).font(.caption2).lineLimit(1).accessibilityIdentifier("manage.fixture.evidence")
            }
            #endif
            if let message = workspace.recoveryError ?? workspace.error ?? connection.errorMessage {
                Text(message).font(.callout).foregroundStyle(.red).padding().accessibilityIdentifier("connection.error")
                    .dismissSidebarOnTap($model.sidebarExpanded)
            }
        }
    }
    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { model.sidebarExpanded.toggle() } label: { Image(systemName: "sidebar.left") }
                .accessibilityLabel(model.sidebarExpanded ? "Collapse sessions" : "Expand sessions")
                .accessibilityIdentifier("sessions.toggle")
        }
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text(workspace.selected?.name ?? "Chadmux").font(.headline).lineLimit(1)
                if model.hosts.count > 1 || workspace.selected != nil {
                    // The host badge: which host this tab (or screen) belongs to.
                    Text(workspace.hostLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        .accessibilityIdentifier("session.host")
                }
            }
            .frame(maxWidth:.infinity)
            .dismissSidebarOnTap($model.sidebarExpanded)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                if model.sidebarExpanded { model.sidebarExpanded = false }
                else { settings = true }
            } label: { Image(systemName: "gearshape") }.accessibilityLabel("Connection settings")
        }
    }
    private var creatingSheet: Binding<Bool> { Binding(get: { creatingOn != nil }, set: { if !$0 { creatingOn = nil } }) }
    private var endingAlert: Binding<Bool> { Binding(get: { ending != nil }, set: { if !$0 { ending = nil } }) }
    private var verifyingAlert: Binding<Bool> { Binding(get: { model.verifying != nil }, set: { _ in }) }
    private var closingDialog: Binding<Bool> { Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }) }
    private var verifyingLabel: String { model.verifying?.host.label ?? "the host" }

    private func presentations(_ view: some View) -> some View {
        hostPresentations(sessionPresentations(view))
    }
    private func sessionPresentations(_ view: some View) -> some View {
        view
            .sheet(isPresented: creatingSheet) {
                if let id = creatingOn, let target = model.workspace(for: id) {
                    NewSessionSheet(workspace: target, host: target.hostLabel) { model.selectedHostID = id }
                }
            }
            .sheet(item: $renaming) { target in
                if let workspace = model.workspace(for: target.host) {
                    RenameSessionSheet(workspace: workspace, session: target.session, host: workspace.hostLabel)
                }
            }
            .alert("End “\(ending?.session.name ?? "")”?", isPresented: endingAlert, presenting: ending) { target in
                Button("Cancel", role: .cancel) { ending = nil }
                Button("End session", role: .destructive) {
                    ending = nil
                    Task { await model.workspace(for: target.host)?.endSession(target.session) }
                }
            } message: { target in
                Text("This ends everything running in “\(target.session.name)” on \(model.host(target.host)?.label ?? "this host"), including any Claude conversation in it. It can’t be undone. An open tab keeps its unsent draft.")
            }
    }
    private func hostPresentations(_ view: some View) -> some View {
        view
            .alert("Verify \(verifyingLabel)’s host key", isPresented: verifyingAlert) {
                Button("Cancel", role: .cancel) { model.verifying?.workspace.cancelHostVerification() }
                Button("Trust verified key") { model.verifying?.workspace.trustResumeHost() }
            } message: {
                Text("Compare this fingerprint with \(verifyingLabel)’s SSH host key before trusting it:\n\n" + (model.verifying?.workspace.verificationTransport?.unknownHost?.fingerprint ?? ""))
            }
            .confirmationDialog("Close this tab and discard its unsent draft?", isPresented: closingDialog) {
                Button("Discard draft and close", role: .destructive) {
                    if let closing { model.workspace(for: closing.host)?.close(closing.tab) }
                    closing = nil
                }
            }
    }
    private var sessionSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(model.orderedWorkspaces, id: \.host.id) { entry in
                    HostSidebarSection(model: model, host: entry.host, workspace: entry.workspace, connection: entry.workspace.connection,
                        onScreen: model.selectedHostID == entry.host.id,
                        create: { creatingOn = entry.host.id },
                        end: { ending = ($0, entry.host.id) },
                        close: { closing = ($0, entry.host.id) },
                        rename: { renaming = RenameTarget(session: $0, host: entry.host.id) })
                }
            }.padding(.vertical, 8)
        }.accessibilityIdentifier("sessions.sidebar")
    }
}



struct SessionTerminal: View {
    @ObservedObject var tab: SessionTab
    @ObservedObject var transport: MacTransport
    var body: some View {
        VStack(spacing: 0) {
            if transport.connected {
                TerminalSurface(terminal: transport.terminal)
                    .accessibilityIdentifier("terminal.surface")
                    .allowsHitTesting(!tab.sending)
                    .overlay(alignment:.bottomTrailing) {
                        if transport.showLiveReturn {
                            Button { Task { await transport.returnToLive() } } label: {
                                Image(systemName:"arrow.down.to.line").frame(width:44,height:44)
                            }
                            .background(.ultraThinMaterial,in:Circle()).padding(8)
                            .accessibilityLabel("Return to live terminal")
                            .accessibilityHint("Leave tmux history in the active pane")
                            .disabled(transport.returningLive || tab.sending)
                        }
                    }
            }
            else {
                ContentUnavailableView(transport.status, systemImage: "terminal", description: Text(transport.errorMessage ?? "The remote tmux session continues while this phone is disconnected."))
            }
            if let error = transport.errorMessage, transport.connected {
                Text(error).font(.callout).foregroundStyle(.red).padding()
                    .accessibilityIdentifier("session.error")
            }
            #if DEBUG
            if transport.nativeScrollFixture { Text(transport.nativeScrollEvidence).font(.caption).accessibilityIdentifier("native.fixture.evidence").accessibilityValue(transport.nativeScrollPosition) }
            #endif
            MessageComposer(tab: tab, transport: transport)
        }
    }
}

private extension View {
    func dismissSidebarOnTap(_ expanded:Binding<Bool>) -> some View {
        overlay {
            if expanded.wrappedValue {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { expanded.wrappedValue = false }
                    .accessibilityHidden(true)
            }
        }
    }
}
