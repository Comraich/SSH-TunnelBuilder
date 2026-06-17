import SwiftUI
import CoreSpotlight
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var connectionStore: ConnectionStore
    @State private var showingErrorSheet = false
    @State private var errorMessage = ""

    // MARK: Import / Export flow

    private enum ExportScope: Equatable { case all, selected }

    /// Drives the passphrase sheet. The file dialogs (`isExportingFile` /
    /// `isImportingFile`) are separate triggers because they run before (import)
    /// or after (export) the passphrase step, never at the same time.
    private enum TransferFlow: Equatable {
        case idle
        case exportPassphrase(ExportScope)
        case importPassphrase(Data)
    }

    @State private var transferFlow: TransferFlow = .idle
    @State private var exportDocument: EncryptedExportDocument?
    @State private var isExportingFile = false
    @State private var isImportingFile = false
    @State private var suggestedExportName = "SSH Connections"

    init(connectionStore: ConnectionStore) {
        _connectionStore = State(initialValue: connectionStore)
    }

    var body: some View {
        NavigationSplitView {
            NavigationList(
                connectionStore: connectionStore,
                selectedConnection: $connectionStore.selectedConnection,
                mode: $connectionStore.mode
            )
            .environment(connectionStore)
            .accessibilityIdentifier("NavigationList")
        } detail: {
            MainView(selectedConnection: $connectionStore.selectedConnection)
                .environment(connectionStore)
                .accessibilityIdentifier("MainView")
        }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            // The user tapped one of our connections in Spotlight: select it.
            guard
                let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                let uuid = UUID(uuidString: identifier),
                let match = connectionStore.connections.first(where: { $0.id == uuid })
            else { return }
            connectionStore.mode = .view
            connectionStore.selectedConnection = match
        }
        .onChange(of: connectionStore.errorAlert) { _, newValue in
            if let error = newValue {
                errorMessage = error.message
                showingErrorSheet = true
                // Clear the error after capturing it
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(100))
                    connectionStore.errorAlert = nil
                }
            }
        }
        .onChange(of: connectionStore.transferRequest) { _, request in
            guard let request else { return }
            connectionStore.transferRequest = nil
            handleTransferRequest(request)
        }
        .sheet(isPresented: $showingErrorSheet) {
            ErrorSheetView(message: errorMessage, isPresented: $showingErrorSheet)
        }
        .alert(item: $connectionStore.hostKeyRequest) { request in
            if request.isMismatch {
                // Re-trust prompt: the previously pinned key no longer matches.
                // Use a destructive primary button so the user has to deliberately
                // overwrite the pinned key — this path could otherwise mask a MITM.
                return Alert(
                    title: Text("Host Key Changed"),
                    message: Text("The host key for '\(request.hostname)' has changed since it was last trusted.\n\nNew fingerprint:\n\(request.fingerprint)\n\nThis can happen if the server was reinstalled or rekeyed — or it could indicate a man-in-the-middle attack. Only trust the new key if you are sure it is legitimate."),
                    primaryButton: .destructive(Text("Trust New Key")) {
                        request.completion(true)
                    },
                    secondaryButton: .cancel(Text("Cancel")) {
                        request.completion(false)
                    }
                )
            }
            return Alert(
                title: Text("Unknown Host"),
                message: Text("The host '\(request.hostname)' is unknown.\n\nFingerprint:\n\(request.fingerprint)\n\nDo you want to trust this host?"),
                primaryButton: .default(Text("Trust")) {
                    request.completion(true)
                },
                secondaryButton: .cancel(Text("Cancel")) {
                    request.completion(false)
                }
            )
        }
        // Each transfer presentation lives on its own hidden host view. macOS
        // SwiftUI only reliably drives one presentation per view, so stacking the
        // passphrase sheet and the save/open panels on the same view as the error
        // sheet + host-key alert caused them to be silently swallowed.
        .background {
            Color.clear
                .sheet(isPresented: passphraseSheetPresented) {
                    passphraseSheetContent
                }
        }
        .background {
            Color.clear
                .fileExporter(
                    isPresented: $isExportingFile,
                    document: exportDocument,
                    contentType: .sshTunnelsExport,
                    defaultFilename: suggestedExportName
                ) { result in
                    if case .failure(let error) = result {
                        connectionStore.errorAlert = ErrorAlert(message: "Export failed: \(error.localizedDescription)")
                    }
                    exportDocument = nil
                }
        }
        .background {
            Color.clear
                .fileImporter(
                    isPresented: $isImportingFile,
                    allowedContentTypes: [.sshTunnelsExport, .json],
                    allowsMultipleSelection: false
                ) { result in
                    handleImportSelection(result)
                }
        }
    }

    // MARK: - Transfer flow plumbing

    private var passphraseSheetPresented: Binding<Bool> {
        Binding(
            get: { transferFlow != .idle },
            set: { presented in if !presented { transferFlow = .idle } }
        )
    }

    @ViewBuilder
    private var passphraseSheetContent: some View {
        switch transferFlow {
        case .exportPassphrase(let scope):
            PassphrasePromptView(
                purpose: .encrypt(connectionCount: connections(for: scope).count),
                onSubmit: { beginEncrypt(scope: scope, passphrase: $0) },
                onCancel: { transferFlow = .idle }
            )
        case .importPassphrase(let data):
            PassphrasePromptView(
                purpose: .decrypt,
                onSubmit: { finishImport(data: data, passphrase: $0) },
                onCancel: { transferFlow = .idle }
            )
        case .idle:
            EmptyView()
        }
    }

    private func connections(for scope: ExportScope) -> [Connection] {
        switch scope {
        case .all: return connectionStore.connections
        case .selected: return [connectionStore.selectedConnection].compactMap { $0 }
        }
    }

    private func handleTransferRequest(_ request: ConnectionStore.TransferRequest) {
        switch request {
        case .exportAll:
            guard !connectionStore.connections.isEmpty else {
                connectionStore.errorAlert = ErrorAlert(message: "There are no connections to export.")
                return
            }
            suggestedExportName = "SSH Connections"
            transferFlow = .exportPassphrase(.all)
        case .exportSelected:
            guard let selected = connectionStore.selectedConnection else {
                connectionStore.errorAlert = ErrorAlert(message: "Select a connection to export first.")
                return
            }
            let name = selected.connectionInfo.name
            suggestedExportName = name.isEmpty ? "SSH Connection" : name
            transferFlow = .exportPassphrase(.selected)
        case .importConnections:
            isImportingFile = true
        }
    }

    /// Builds the payload (reading secrets from the Keychain on the main actor),
    /// then encrypts off the main actor — PBKDF2 at 600k iterations is slow.
    private func beginEncrypt(scope: ExportScope, passphrase: String) {
        let payload = connectionStore.makeExportPayload(for: connections(for: scope))
        transferFlow = .idle // dismiss the passphrase sheet before presenting the save panel
        Task {
            do {
                let data = try await Task.detached {
                    try ConnectionTransfer.encrypt(payload, passphrase: passphrase)
                }.value
                exportDocument = EncryptedExportDocument(data: data)
                isExportingFile = true
            } catch {
                connectionStore.errorAlert = ErrorAlert(message: errorText(error))
            }
        }
    }

    private func handleImportSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            // Files chosen via the open panel are security-scoped in the sandbox.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                transferFlow = .importPassphrase(data)
            } catch {
                connectionStore.errorAlert = ErrorAlert(message: "Couldn’t read the file: \(error.localizedDescription)")
            }
        case .failure(let error):
            connectionStore.errorAlert = ErrorAlert(message: "Import failed: \(error.localizedDescription)")
        }
    }

    private func finishImport(data: Data, passphrase: String) {
        transferFlow = .idle // dismiss the passphrase sheet
        Task {
            do {
                let payload = try await Task.detached {
                    try ConnectionTransfer.decrypt(data, passphrase: passphrase)
                }.value
                connectionStore.importConnections(from: payload)
            } catch {
                connectionStore.errorAlert = ErrorAlert(message: errorText(error))
            }
        }
    }

    private func errorText(_ error: Error) -> String {
        (error as? ConnectionTransferError)?.errorDescription ?? error.localizedDescription
    }
}

// MARK: - Error Sheet View

struct ErrorSheetView: View {
    let message: String
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 50))
                .foregroundStyle(.red)

            Text("Error")
                .font(.title)
                .fontWeight(.bold)

            Text(message)
                .font(.body)
                .multilineTextAlignment(.center)
                .padding()

            Button("OK") {
                isPresented = false
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(30)
        .frame(minWidth: 400, minHeight: 250)
    }
}

#Preview("Empty State") {
    ContentView(connectionStore: ConnectionStore(mode: .view, connections: []))
}

#Preview("With Connections") {
    ContentView(connectionStore: ConnectionStore(mode: .view, connections: SampleData.connections))
}
