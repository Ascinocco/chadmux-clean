import SwiftUI

/// One host in the sidebar: its status, connect, new session and refresh, and
/// its sessions. Each host is independent, so an offline one blocks nothing.
struct HostSidebarSection: View {
    @ObservedObject var model: HostsModel
    let host: HostProfile
    @ObservedObject var workspace: SessionWorkspace
    @ObservedObject var connection: MacTransport
    let onScreen: Bool
    let create: () -> Void
    let end: (RemoteSession) -> Void
    let close: (String) -> Void
    var rename: (RemoteSession) -> Void = { _ in }
    private var busy: Bool { [.reconnecting,.discovering,.attaching].contains(workspace.resumeState) }
    private var status: String {
        busy ? workspace.resumeState.rawValue : connection.connected ? "Connected" : workspace.resumeState == .unavailable ? "Offline" : connection.status
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(connection.connected ? Color.green : busy ? .orange : .secondary).frame(width: 8, height: 8)
                Text(host.label).font(.headline).lineLimit(1)
                Spacer(minLength: 2)
                Button(action: create) { Image(systemName: "plus") }
                    .accessibilityLabel("New Claude session on " + host.label)
                    .disabled(!connection.connected)
                Button { Task { await workspace.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("Refresh " + host.label + " sessions")
                    .disabled(!connection.connected || workspace.refreshing)
            }
            HStack(spacing: 6) {
                Text(status).font(.caption).foregroundStyle(.secondary).accessibilityLabel(host.label + " status: " + status)
                Spacer(minLength: 2)
                if !connection.connected && !busy && host.connection.isValid {
                    Button("Connect") { workspace.retryConnection() }.font(.caption)
                        .accessibilityLabel("Connect to " + host.label)
                }
            }
            // The on-screen host's errors show under the terminal; others show here.
            if !onScreen, let message = workspace.recoveryError ?? workspace.error {
                Text(message).font(.caption2).foregroundStyle(.red).accessibilityLabel(host.label + " error: " + message)
            }
            ForEach(workspace.sidebarSessions) { session in
                HStack {
                    Button { model.select(session, on: host.id) } label: {
                        Text(session.name).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                    }.accessibilityIdentifier("session." + host.label + "." + session.id)
                    if workspace.sessions.contains(where: { $0.id == session.id && $0.instance == session.instance }) {
                        Button { rename(session) } label: { Image(systemName: "pencil").font(.caption) }
                            .accessibilityLabel("Rename session " + session.name + " on " + host.label)
                            .disabled(!connection.connected || workspace.renamingSessionID != nil)
                        Button { end(session) } label: {
                            if workspace.endingSessionID == session.id { ProgressView().controlSize(.mini) }
                            else { Image(systemName: "minus.circle").font(.caption).foregroundStyle(.red) }
                        }
                        .accessibilityLabel("End session " + session.name + " on " + host.label)
                        .disabled(!connection.connected || workspace.endingSessionID != nil)
                    }
                    if workspace.tabs.contains(where: { $0.id == session.id }) {
                        Button {
                            if let tab = workspace.tabs.first(where: { $0.id == session.id }), !tab.draft.isEmpty || !tab.attachments.isEmpty || tab.pendingTranscript != nil || workspace.voice.origin === tab { close(session.id) }
                            else { workspace.close(session.id) }
                        } label: { Image(systemName: "xmark").font(.caption) }
                            .accessibilityLabel("Close " + session.name + " on " + host.label)
                    }
                }.padding(8).background(onScreen && workspace.selectedID == session.id ? Color.green.opacity(0.2) : .clear)
                .contextMenu {
                    if workspace.sessions.contains(where: { $0.id == session.id && $0.instance == session.instance }) && connection.connected {
                        Button { rename(session) } label: { Label("Rename", systemImage: "pencil") }
                        Button(role: .destructive) { end(session) } label: { Label("End Session", systemImage: "minus.circle") }
                    }
                }
            }
            if workspace.sidebarSessions.isEmpty {
                Text(connection.connected ? "No sessions yet. Tap + to start one." : "Connect to see its sessions.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 8)
    }
}

struct NewSessionSheet: View {
    @ObservedObject var workspace: SessionWorkspace
    let host: String
    /// After the session is created and its tab opened (the host goes on screen).
    var onCreated: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var folder = ""
    @State private var error: String?
    private var nameProblem: String? {
        name.isEmpty || ClaudeTmux.validName(name) ? nil : "Use 1–64 letters, numbers, hyphens or underscores."
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .plainTextInput()
                        .accessibilityIdentifier("newSession.name")
                    if let nameProblem { Text(nameProblem).font(.caption).foregroundStyle(.red).accessibilityIdentifier("newSession.nameProblem") }
                } header: { Text("Session name") } footer: { Text("Letters, numbers, hyphens and underscores.") }
                Section {
                    TextField("Folder", text: $folder)
                        .plainTextInput()
                        .accessibilityIdentifier("newSession.folder")
                } header: { Text("Folder on \(host)") } footer: { Text("Claude starts in this folder. ~ means your home folder.") }
                if let error {
                    Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("newSession.error") }
                }
            }
            .navigationTitle("New Claude session")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(workspace.creatingSession)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if workspace.creatingSession { ProgressView().accessibilityIdentifier("newSession.progress") }
                    else {
                        Button("Create") {
                            Task {
                                error = nil
                                if let message = await workspace.createSession(name: name, folder: folder) { error = message }
                                else { onCreated(); dismiss() }
                            }
                        }
                        .disabled(!ClaudeTmux.validName(name) || folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("newSession.create")
                    }
                }
            }
            .interactiveDismissDisabled(workspace.creatingSession)
            .onAppear { folder = workspace.newSessionFolder }
        }
    }
}

/// Which session a rename sheet is for.
struct RenameTarget: Identifiable {
    let session: RemoteSession
    let host: UUID
    var id: String { host.uuidString + "/" + session.id }
}

/// Renames the real tmux session (tmux stays the source of truth). Tabs, drafts
/// and images follow the session, which keeps its id.
struct RenameSessionSheet: View {
    @ObservedObject var workspace: SessionWorkspace
    let session: RemoteSession
    let host: String
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    private var renaming: Bool { workspace.renamingSessionID == session.id }
    private var nameProblem: String? {
        name.isEmpty || ClaudeTmux.validNewName(name) ? nil : "Use 1–64 letters, numbers, hyphens or underscores, not starting with a hyphen."
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .plainTextInput()
                        .accessibilityIdentifier("renameSession.name")
                        .onSubmit(rename)
                    if let nameProblem { Text(nameProblem).font(.caption).foregroundStyle(.red).accessibilityIdentifier("renameSession.nameProblem") }
                } header: { Text("New name for “\(session.name)” on \(host)") } footer: {
                    Text("Renames the tmux session itself, so every device and terminal sees the new name. Anything running in it keeps running.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).accessibilityIdentifier("renameSession.error") }
                }
            }
            .navigationTitle("Rename session")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(renaming)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if renaming { ProgressView().accessibilityIdentifier("renameSession.progress") }
                    else {
                        Button("Rename", action: rename)
                            .disabled(!ClaudeTmux.validNewName(name))
                            .accessibilityIdentifier("renameSession.rename")
                    }
                }
            }
            .interactiveDismissDisabled(renaming)
            .onAppear { name = session.name }
        }
    }
    private func rename() {
        guard ClaudeTmux.validNewName(name), !renaming else { return }
        Task {
            error = nil
            if let message = await workspace.renameSession(session, to: name) { error = message } else { dismiss() }
        }
    }
}

struct WorkspaceConnectionBar: View {
    @ObservedObject var workspace:SessionWorkspace
    @ObservedObject var connection:MacTransport
    @ObservedObject var terminal:MacTransport
    private var busy:Bool { [.reconnecting,.discovering,.attaching].contains(workspace.resumeState) }
    private var ready:Bool { terminal.connected && !busy }
    var body:some View {
        HStack {
            Circle().fill(ready ? .green : .secondary).frame(width:8,height:8)
            Text(busy ? workspace.resumeState.rawValue : (ready ? "Connected" : terminal.status))
                .font(.caption).accessibilityIdentifier("connection.status")
            Spacer()
            if !busy && !ready && connection.profile.isValid {
                Button(workspace.resumeDesired || workspace.resumeState == .unavailable ? "Retry" : "Connect") {
                    workspace.retryConnection()
                }.accessibilityIdentifier("connection.connect")
            }
            if connection.connected || busy || workspace.resumeDesired {
                Button("Disconnect") { workspace.disconnect() }.accessibilityIdentifier("connection.disconnect")
            }
        }.padding(.horizontal).padding(.vertical,6)
    }
}
