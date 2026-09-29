import SwiftUI

/// Saved hosts, this device's public key, and the way to add another host.
struct HostsSettings: View {
    @ObservedObject var model: HostsModel
    /// Closes the settings sheet; its owner holds the presentation state.
    let close: () -> Void
    @State private var adding = false
    @State private var firstHost = false
    @State private var offeredFirstHost = false
    var body: some View {
        NavigationStack {
            List {
                Section("Hosts") {
                    ForEach(model.hosts) { host in
                        NavigationLink(value: host.id) {
                            VStack(alignment: .leading) {
                                Text(host.label)
                                Text(host.connection.username + "@" + host.connection.host + (host.connection.port == 22 ? "" : ":\(host.connection.port)"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.accessibilityIdentifier("hosts.row." + host.label)
                    }
                    if model.hosts.count < HostProfile.maximumHosts {
                        Button("Add host") { adding = true }.accessibilityIdentifier("hosts.add")
                    }
                }
                if !model.hosts.isEmpty {
                    Section {
                        Picker("Dictation host", selection: Binding(get: { model.dictationHost?.id }, set: { model.dictationHostID = $0 })) {
                            ForEach(model.hosts) { host in Text(host.label).tag(Optional(host.id)) }
                        }.accessibilityIdentifier("hosts.dictation")
                    } header: { Text("Dictation") } footer: {
                        Text("Dictation from a tab on any host is transcribed by the companion server on this host, over SSH, using the transcription token saved for it. Only its loopback /transcriptions is reached.")
                    }
                }
                DeviceKeySection(publicKey: model.publicKey)
                Section("Before connecting") {
                    Text("Each host needs OpenSSH (on a Mac: Remote Login) reachable over Tailscale, this device's public key in ~/.ssh/authorized_keys, and tmux. Verify a host's fingerprint with ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub on that host.")
                }
            }
            .navigationTitle("Hosts")
            .inlineNavigationTitle()
            .navigationDestination(for: UUID.self) { id in
                if let host = model.host(id) { HostEditor(model: model, existing: host) { } }
            }
            .navigationDestination(isPresented: $adding) {
                HostEditor(model: model, existing: nil, suggested: model.hosts.isEmpty ? HostProfile.firstHostSuggestion : nil) {
                    if firstHost { close() } else { adding = false }
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { close() }.accessibilityIdentifier("hosts.done") }
            }
            .onAppear {
                // Open straight into adding the first host, once: Cancel returns here.
                guard !offeredFirstHost else { return }
                offeredFirstHost = true
                if model.hosts.isEmpty { firstHost = true; adding = true }
            }
        }.tint(.green)
    }
}

struct DeviceKeySection: View {
    let publicKey: String
    var body: some View {
        Section("This device’s SSH key") {
            Text("Add this public key to ~/.ssh/authorized_keys on each host. The private key stays in this device’s Keychain.")
            Text(publicKey).font(.caption.monospaced()).textSelection(.enabled)
            Button("Copy public key") { Pasteboard.copy(publicKey) }
                .disabled(publicKey.isEmpty)
        }
    }
}

/// Adds or edits one host. The endpoint is locked while that host has tabs.
struct HostEditor: View {
    @ObservedObject var model: HostsModel
    let existing: HostProfile?
    /// Prefills a new host (the first host: this Mac on macOS, "Mac" on iOS).
    var suggested: HostProfile? = nil
    let saved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var host = ""
    @State private var username = ""
    @State private var port = "22"
    @State private var folder = "~"
    @State private var transcriptionToken = ""
    @State private var error: String?
    @State private var forgetTrust = false
    @State private var confirmRemove = false
    @State private var probe: SSHProbe.Result?
    @State private var probing = false
    private var workspace: SessionWorkspace? { existing.flatMap { model.workspace(for: $0.id) } }
    private var locked: Bool { !(workspace?.tabs.isEmpty ?? true) }
    private var candidate: MacConnection {
        MacConnection(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: Int(port) ?? 0,
                      username: username.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    var body: some View {
        Form {
            if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("host.error") }
            if locked { Text("Close this host’s tabs before changing its address, username or port.").font(.caption) }
            Section("Host") {
                TextField("Label (e.g. Mac, Arch)", text: $label)
                    .autocorrectionDisabled().accessibilityIdentifier("host.label")
                TextField("Tailscale hostname or IP", text: $host)
                    .plainTextInput().accessibilityIdentifier("connection.host").disabled(locked)
                TextField("Username", text: $username)
                    .plainTextInput().accessibilityIdentifier("connection.username").disabled(locked)
                TextField("SSH port", text: $port).numberInput().accessibilityIdentifier("connection.port").disabled(locked)
            }
            Section {
                TextField("Default folder", text: $folder)
                    .plainTextInput().accessibilityIdentifier("host.folder")
            } header: { Text("New sessions") } footer: { Text("Offered when you create a Claude session on this host. ~ means the home folder.") }
            Section {
                Button(probing ? "Checking…" : "Check SSH") {
                    let target = candidate
                    probing = true; probe = nil
                    Task { probe = await SSHProbe.probe(host: target.host, port: target.port); probing = false }
                }
                .disabled(probing || !candidate.isValid).accessibilityIdentifier("host.check")
                if let probe {
                    Text(probe.message + (probe == .unreachable && HostProfile.isThisMac(candidate.host) ? " On this Mac, turn on Remote Login in System Settings › General › Sharing (allow your user only)." : ""))
                        .font(.caption).foregroundStyle(probe.isProblem ? .red : .secondary).accessibilityIdentifier("host.probe")
                }
            } header: { Text("Reachability") } footer: { Text("Chadmux connects to OpenSSH with this device's key. Tailscale SSH must be off on the host.") }
            DeviceKeySection(publicKey: model.publicKey)
            Section("Optional dictation") {
                SecureField("Transcription token", text: $transcriptionToken)
                    .plainTextInput()
                Text("The dedicated transcription token for the companion server on this host, used when it is the dictation host. It stays in Keychain. Leave it blank if this host doesn’t transcribe.")
            }
            Section("Photo storage") {
                Text("Up to eight images per message. Images are resized to a 2048-pixel edge and sent only when you tap Send. Remote copies stay in ~/.chadmux/uploads on the session’s host until you remove them there; keep them while Claude still needs them.")
            }
            if let existing {
                Section("Host verification") {
                    Button("Forget saved host trust", role: .destructive) { forgetTrust = true }
                        .disabled(workspace?.connection.connected == true || workspace?.connection.connecting == true)
                    Text("Only reset trust after independently verifying a host-key change on that host. The next connection will ask you to verify its fingerprint again.")
                }
                Section {
                    Button("Remove host", role: .destructive) { confirmRemove = true }.accessibilityIdentifier("host.remove")
                }
            }
        }
        // On the form, not a section: dialogs attached inside list rows can stop responding.
        .confirmationDialog("Remove \(existing?.label ?? "host")?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove host", role: .destructive) {
                guard let existing else { return }
                do { try model.remove(existing.id); dismiss() }
                catch { self.error = "Could not remove the host. Try again." }
            }
        } message: {
            Text((workspace?.tabs.isEmpty ?? true) ? "Its sessions keep running on the host." : "Its open tabs close and their unsent drafts are discarded. Its sessions keep running on the host.")
        }
        .navigationTitle(existing == nil ? "Add host" : existing!.label)
        .inlineNavigationTitle()
        .navigationBarBackButtonHidden(existing == nil)
        .toolbar {
            if existing == nil {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { saved() }.accessibilityIdentifier("host.cancel") }
            }
            ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.accessibilityIdentifier("connection.save") }
        }
        .confirmationDialog("Forget trust for \(existing?.label ?? "this host")?", isPresented: $forgetTrust) {
            Button("Forget host key", role: .destructive) {
                guard let existing else { return }
                do { try model.secrets.remove(existing.connection.trustID) }
                catch { self.error = "Could not remove the saved host key." }
            }
        }
        .onAppear {
            let source = existing ?? suggested ?? HostProfile(label: "", connection: MacConnection())
            label = source.label; host = source.connection.host; username = source.connection.username
            port = String(source.connection.port); folder = source.defaultFolder
            loadToken()
        }
        .onChange(of: host) { _, _ in loadToken() }
        .onChange(of: port) { _, _ in loadToken() }
    }

    private func save() {
        let profile = HostProfile(id: existing?.id ?? UUID(), label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                                  connection: candidate, defaultFolder: folder.trimmingCharacters(in: .whitespacesAndNewlines))
        if let problem = profile.problem { error = problem; return }
        do {
            if transcriptionToken.isEmpty { try model.secrets.remove(profile.connection.apiTokenID) }
            else { try model.secrets.write(Data(transcriptionToken.utf8), account: profile.connection.apiTokenID) }
            if existing == nil { try model.add(profile) } else { try model.update(profile) }
            if existing == nil { saved() } else { dismiss() }
        } catch is SecretStore.StorageError {
            error = "Could not save to Keychain. Unlock the device and try again."
        } catch is HostsModel.TabsOpen {
            error = "Close this host’s tabs before changing its address, username or port."
        } catch {
            self.error = "Another host already uses that label or that user and address."
        }
    }
    private func loadToken() {
        do { transcriptionToken = try model.secrets.read(candidate.apiTokenID).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
        catch { transcriptionToken = ""; self.error = "Could not open Keychain. Unlock the device and try again." }
    }
}
