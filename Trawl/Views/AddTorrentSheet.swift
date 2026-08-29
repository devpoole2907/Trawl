import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct AddTorrentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncService.self) private var syncService
    @Environment(TorrentService.self) private var torrentService
    /// Optional so the sheet still works when it's presented from a host that
    /// doesn't inject the SABnzbd manager — it then degrades to torrent-only.
    @Environment(SABnzbdServiceManager.self) private var sabnzbdServiceManager: SABnzbdServiceManager?
    @Query private var servers: [ServerProfile]
    @Query private var sabnzbdProfiles: [SABnzbdServiceProfile]
    @State private var viewModel: AddTorrentViewModel?
    @State private var showFilePicker = false

    let initialMagnetURL: String?
    #if DEBUG
    private var skipsAutomaticLoading = false
    #endif

    init(initialMagnetURL: String? = nil) {
        self.initialMagnetURL = initialMagnetURL
    }

    var body: some View {
        AppSheetShell(
            title: "Add Download",
            confirmTitle: confirmTitle,
            isConfirmDisabled: !(viewModel?.canSubmit ?? false),
            onConfirm: {
                guard let vm = viewModel else { return }
                Task {
                    if await vm.submit(modelContext: modelContext) {
                        dismiss()
                    }
                }
            },
            confirmPlacement: .prominentBottom,
            detents: [.large],
            dragIndicator: .visible
        ) {
            Group {
                if !hasAnyClient {
                    noClientsState
                } else if let vm = viewModel {
                    addDownloadForm(vm: vm)
                } else {
                    ProgressView()
                }
            }
            #if os(macOS)
            .frame(minWidth: 620, idealWidth: 700, minHeight: 540)
            #endif
            .task {
                #if DEBUG
                guard !skipsAutomaticLoading else { return }
                #endif
                if viewModel == nil {
                    let vm = AddTorrentViewModel(
                        torrentService: torrentService,
                        syncService: syncService,
                        sabnzbdManager: sabnzbdServiceManager
                    )
                    vm.hasQBittorrent = hasQBittorrentServer
                    vm.hasSABnzbd = hasSABnzbdServer
                    viewModel = vm
                    await vm.loadDefaults(modelContext: modelContext)
                    if let url = initialMagnetURL {
                        if vm.hasQBittorrent {
                            vm.source = .magnet
                            vm.magnetLink = url
                        } else {
                            // Without qBittorrent there's nowhere to send a magnet,
                            // so show it on the URL source, which explains why.
                            vm.source = .url
                            vm.linkURL = url
                        }
                    }
                    // A SABnzbd-only setup has no magnet source to land on.
                    vm.normalizeSourceForAvailableClients()
                }
            }
        }
    }

    @ViewBuilder
    private func addDownloadForm(vm: AddTorrentViewModel) -> some View {
        @Bindable var vm = vm
        Form {
            destinationSection(vm: vm)

            Section(footer: Text(vm.source.footerText)) {
                inputSection(vm: vm)
            }

            if let destination = vm.destination {
                switch destination {
                case .qBittorrent:
                    qBittorrentOptionsSection(vm: vm)
                case .sabnzbd:
                    sabnzbdOptionsSection(vm: vm)
                }
            }

            if let warning = vm.routingWarning {
                Section {
                    Label(warning, systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
            }

            if vm.isSubmitting {
                Section {
                    HStack {
                        ProgressView()
                        Text(submissionText(vm: vm))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let error = vm.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .safeAreaInset(edge: .top) {
            sourceSegmentBar(vm: vm)
        }
        .alert(item: Binding(
            get: { vm.submissionErrorAlert },
            set: { vm.submissionErrorAlert = $0 }
        )) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: Self.importContentTypes(for: vm.source)
        ) { result in
            handleFileImport(result, vm: vm)
        }
        #if os(macOS)
        .formStyle(.grouped)
        .padding(20)
        .frame(maxWidth: 760, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        #endif
    }

    // MARK: - Sections

    @ViewBuilder
    private func destinationSection(vm: AddTorrentViewModel) -> some View {
        @Bindable var vm = vm
        Section {
            // Only ask where a link should go when the app genuinely can't tell
            // and both clients could take it.
            if vm.needsURLDestinationChoice {
                Picker("Client", selection: $vm.preferredURLDestination) {
                    Text(AddDownloadDestination.qBittorrent.displayName)
                        .tag(AddDownloadDestination.qBittorrent)
                    Text(AddDownloadDestination.sabnzbd.displayName)
                        .tag(AddDownloadDestination.sabnzbd)
                }
            }

            if let destination = vm.destination, let server = serverSummary(for: destination) {
                LabeledContent(destination.displayName) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(server.name)
                        Text(server.host)
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .multilineTextAlignment(.trailing)
                }
            }
        } header: {
            Text("Destination")
        } footer: {
            if vm.needsURLDestinationChoice {
                Text("Trawl can't tell what this link is, so choose the client that should fetch it.")
            }
        }
    }

    /// Source selector. Hidden when the configured clients only allow one source,
    /// so a SAB-only or qBittorrent-only setup doesn't get a one-item bar.
    @ViewBuilder
    private func sourceSegmentBar(vm: AddTorrentViewModel) -> some View {
        if vm.availableSources.count > 1 {
            TrawlSegmentBar(
                "Source",
                selection: Binding(
                    get: { vm.source },
                    set: { newSource in
                        guard newSource != vm.source else { return }
                        withAnimation {
                            vm.source = newSource
                            vm.error = nil
                            vm.clearInputOtherThanCurrentSource()
                        }
                    }
                ),
                items: vm.availableSources.map(\.segmentBarItem),
                alignment: .leading
            )
        }
    }

    @ViewBuilder
    private func inputSection(vm: AddTorrentViewModel) -> some View {
        @Bindable var vm = vm
        switch vm.source {
        case .magnet:
            linkTextField(placeholder: "magnet:?xt=urn:btih:...", text: $vm.magnetLink)
        case .url:
            linkTextField(placeholder: "https://example.com/file.nzb", text: $vm.linkURL)
        case .torrentFile:
            filePickerRow(fileName: vm.torrentFileName, selectTitle: "Select .torrent File")
        case .nzbFile:
            filePickerRow(fileName: vm.nzbFileName, selectTitle: "Select .nzb File")
        }
    }

    @ViewBuilder
    private func qBittorrentOptionsSection(vm: AddTorrentViewModel) -> some View {
        @Bindable var vm = vm
        Section {
            LabeledContent("Save Path") {
                TextField(vm.serverDefaultSavePath ?? "Server default", text: $vm.savePath)
                    .multilineTextAlignment(.trailing)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }

            if !vm.recentSavePaths.isEmpty {
                Menu {
                    ForEach(vm.recentSavePaths, id: \.path) { recent in
                        Button(recent.path) {
                            vm.savePath = recent.path
                        }
                    }
                } label: {
                    Label("Recent Paths", systemImage: "clock.arrow.circlepath")
                        .font(.subheadline)
                }
            }

            if !vm.availableCategories.isEmpty {
                Picker("Category", selection: $vm.selectedCategory) {
                    Text("None").tag("")
                    ForEach(vm.availableCategories, id: \.self) { cat in
                        Text(cat).tag(cat)
                    }
                }
            }

            Toggle("Start Paused", isOn: $vm.startPaused)
            Toggle("Sequential Download", isOn: $vm.sequentialDownload)
            Toggle("First and Last Pieces First", isOn: $vm.firstLastPiecePriority)
        } header: {
            Text("Options")
        } footer: {
            Text("Leave Save Path blank to use the server default. Recent Paths lets you quickly reuse a location. Enabling first and last pieces first helps with early video previewing.")
        }
    }

    @ViewBuilder
    private func sabnzbdOptionsSection(vm: AddTorrentViewModel) -> some View {
        @Bindable var vm = vm
        Section {
            // Categories come from SABnzbd's own `get_cats`, falling back to the ones
            // seen on existing jobs if that call fails. The free-text field is the last
            // resort — typing a category that doesn't exist is silently ignored by the
            // server, so a picker is worth having wherever we can build one.
            if vm.sabCategories.isEmpty {
                LabeledContent("Category") {
                    TextField("Server default", text: $vm.sabCategory)
                        .multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
            } else {
                Picker("Category", selection: $vm.sabCategory) {
                    Text("Server default").tag("")
                    ForEach(vm.sabCategories, id: \.self) { cat in
                        Text(cat).tag(cat)
                    }
                }
            }

            Picker("Priority", selection: $vm.sabPriority) {
                ForEach(AddDownloadPriority.allCases) { priority in
                    Text(priority.displayName).tag(priority)
                }
            }

            Picker("Post-Processing", selection: $vm.sabPostProcessing) {
                ForEach(AddDownloadPostProcessing.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }

            // Only offered when the server actually reports scripts — most setups
            // have none, and an empty picker reads as something being broken.
            if !vm.sabScripts.isEmpty {
                Picker("Script", selection: $vm.sabScript) {
                    Text("Server default").tag("")
                    ForEach(vm.sabScripts, id: \.self) { script in
                        Text(script).tag(script)
                    }
                }
            }

            LabeledContent("Password") {
                SecureField("Optional", text: $vm.sabPassword)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("Options")
        } footer: {
            Text("Leave Category, Priority and Post-Processing on the server default to use SABnzbd's own settings. A password is only needed for encrypted archives.")
        }
    }

    // MARK: - Rows

    private func linkTextField(placeholder: String, text: Binding<String>) -> some View {
        #if os(iOS)
        return TextField(placeholder, text: text, axis: .vertical)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .lineLimit(3...6)
        #else
        return TextField(placeholder, text: text, axis: .vertical)
            .autocorrectionDisabled()
            .lineLimit(3...6)
        #endif
    }

    @ViewBuilder
    private func filePickerRow(fileName: String?, selectTitle: String) -> some View {
        if let fileName {
            HStack {
                Image(systemName: "doc.fill")
                    .foregroundStyle(.blue)
                Text(fileName)
                    .lineLimit(1)
                Spacer()
                Button("Change") { showFilePicker = true }
                    .font(.caption)
            }
        } else {
            Button {
                showFilePicker = true
            } label: {
                Label(selectTitle, systemImage: "doc.badge.plus")
            }
        }
    }

    private var noClientsState: some View {
        ContentUnavailableView {
            Label("No Download Clients", systemImage: "arrow.down.circle")
        } description: {
            Text("Add a qBittorrent or SABnzbd server before adding downloads.")
        }
        .scrollableUnavailableState()
    }

    // MARK: - File import

    private static func importContentTypes(for source: AddDownloadSource) -> [UTType] {
        switch source {
        case .nzbFile:
            // There's no system UTType for NZB, so declare one from the extension
            // and keep XML/data as a fallback — the pick is validated by extension.
            [UTType(filenameExtension: "nzb") ?? .xml, .xml, .data]
        default:
            [UTType(filenameExtension: "torrent") ?? .data]
        }
    }

    private func handleFileImport(_ result: Result<URL, any Error>, vm: AddTorrentViewModel) {
        switch result {
        case .failure(let error):
            vm.error = error.localizedDescription
        case .success(let url):
            let source = vm.source
            Task {
                guard let picked = await Self.readPickedFile(from: url) else {
                    vm.error = "Couldn't read the selected file."
                    return
                }
                if source == .nzbFile {
                    guard Self.isNZBFileName(picked.fileName) else {
                        vm.error = "Choose a .nzb file."
                        return
                    }
                    vm.nzbFileData = picked.data
                    vm.nzbFileName = picked.fileName
                } else {
                    vm.torrentFileData = picked.data
                    vm.torrentFileName = picked.fileName
                }
                vm.error = nil
            }
        }
    }

    private static func isNZBFileName(_ fileName: String) -> Bool {
        let lowercased = fileName.lowercased()
        return lowercased.hasSuffix(".nzb") || lowercased.hasSuffix(".nzb.gz")
    }

    // MARK: - Client availability

    private var activeServer: ServerProfile? {
        servers.first(where: { $0.isActive }) ?? servers.first
    }

    private var activeSABnzbdProfile: SABnzbdServiceProfile? {
        sabnzbdProfiles.first(where: { $0.isEnabled }) ?? sabnzbdProfiles.first
    }

    private var hasQBittorrentServer: Bool {
        !servers.isEmpty
    }

    private var hasSABnzbdServer: Bool {
        sabnzbdServiceManager != nil && !sabnzbdProfiles.isEmpty
    }

    private var hasAnyClient: Bool {
        hasQBittorrentServer || hasSABnzbdServer
    }

    private func serverSummary(for destination: AddDownloadDestination) -> (name: String, host: String)? {
        switch destination {
        case .qBittorrent:
            guard let server = activeServer else { return nil }
            return (server.displayName, server.hostURL)
        case .sabnzbd:
            guard let profile = activeSABnzbdProfile else { return nil }
            return (profile.displayName, profile.hostURL)
        }
    }

    // MARK: - Sheet chrome

    /// Specific about what's being added, but never client-specific. `nil` hides the
    /// confirm button entirely on the no-clients state.
    private var confirmTitle: String? {
        guard hasAnyClient else { return nil }
        return viewModel?.source.confirmTitle ?? "Add"
    }

    private func submissionText(vm: AddTorrentViewModel) -> String {
        if let destination = vm.destination, let server = serverSummary(for: destination) {
            return "Sending to \(server.name)…"
        }
        return "Adding download…"
    }

    private struct SelectedFile: Sendable {
        let data: Data
        let fileName: String
    }

    private nonisolated static func readPickedFile(from url: URL) async -> SelectedFile? {
        await Task.detached(priority: .userInitiated) {
            guard url.startAccessingSecurityScopedResource() else { return nil }
            defer { url.stopAccessingSecurityScopedResource() }

            guard let data = try? Data(contentsOf: url) else { return nil }
            return SelectedFile(data: data, fileName: url.lastPathComponent)
        }.value
    }
}

#if DEBUG
extension AddTorrentSheet {
    init(previewViewModel: AddTorrentViewModel) {
        self.init(initialMagnetURL: nil)
        self._viewModel = State(initialValue: previewViewModel)
        self.skipsAutomaticLoading = true
    }
}

#Preview("Initial") {
    PreviewHost(profiles: .qBittorrentOnly) {
        AddTorrentSheet(previewViewModel: AddTorrentViewModel(
            previewMagnetLink: "",
            savePath: "",
            selectedCategory: "",
            recentSavePaths: [
                RecentSavePath(path: "/downloads/movies"),
                RecentSavePath(path: "/downloads/tv")
            ]
        ))
    }
}

#Preview("Magnet Input") {
    PreviewHost(profiles: .qBittorrentOnly) {
        AddTorrentSheet(previewViewModel: AddTorrentViewModel())
    }
}

#Preview("Torrent File") {
    PreviewHost(profiles: .qBittorrentOnly) {
        AddTorrentSheet(previewViewModel: AddTorrentViewModel(
            previewSource: .torrentFile,
            previewMagnetLink: "",
            previewTorrentFileName: "ubuntu-24.04-desktop-amd64.iso.torrent",
            previewTorrentFileData: Data([0x64, 0x38, 0x3a]),
            savePath: "/downloads/linux",
            selectedCategory: "linux-isos"
        ))
    }
}

#Preview("NZB File") {
    PreviewHost(profiles: .sabnzbdOnly) {
        AddTorrentSheet(previewViewModel: AddTorrentViewModel(
            previewSource: .nzbFile,
            previewMagnetLink: "",
            previewNZBFileName: "ubuntu.24.04.nzb",
            previewNZBFileData: Data([0x3c, 0x3f, 0x78]),
            hasQBittorrent: false,
            hasSABnzbd: true
        ))
    }
}

#Preview("Ambiguous URL") {
    PreviewHost {
        AddTorrentSheet(previewViewModel: AddTorrentViewModel(
            previewSource: .url,
            previewMagnetLink: "",
            previewLinkURL: "https://indexer.example/api?t=get&id=abc123",
            hasQBittorrent: true,
            hasSABnzbd: true
        ))
    }
}

#Preview("Submitting") {
    PreviewHost(profiles: .qBittorrentOnly) {
        AddTorrentSheet(previewViewModel: AddTorrentViewModel(isSubmitting: true))
    }
}

#Preview("Error") {
    PreviewHost(profiles: .qBittorrentOnly) {
        AddTorrentSheet(previewViewModel: AddTorrentViewModel(
            error: "qBittorrent rejected the magnet link because it is malformed.",
            submissionErrorAlert: ErrorAlertItem(
                title: "Couldn't Add Download",
                message: "qBittorrent rejected the magnet link because it is malformed."
            )
        ))
    }
}

#Preview("No Clients") {
    PreviewHost(profiles: .empty) {
        AddTorrentSheet(previewViewModel: AddTorrentViewModel(
            hasQBittorrent: false,
            hasSABnzbd: false
        ))
    }
}
#endif
