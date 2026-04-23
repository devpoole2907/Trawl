import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct AddTorrentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncService.self) private var syncService
    @Environment(TorrentService.self) private var torrentService
    @Query(filter: #Predicate<ServerProfile> { $0.isActive }) private var activeServers: [ServerProfile]
    @State private var viewModel: AddTorrentViewModel?
    @State private var showFilePicker = false
    @State private var inputTab: AddTorrentInputMode = .magnet

    let initialMagnetURL: String?

    init(initialMagnetURL: String? = nil) {
        self.initialMagnetURL = initialMagnetURL
    }

    var body: some View {
        NavigationStack {
            Group {
                if let vm = viewModel {
                    addTorrentForm(vm: vm)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Add Torrent")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let vm = viewModel else { return }
                        Task {
                            if await vm.submit(modelContext: modelContext) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(!(viewModel?.canSubmit ?? false))
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            #if os(macOS)
            .frame(minWidth: 620, idealWidth: 700, minHeight: 540)
            #endif
            .task {
                if viewModel == nil {
                    let vm = AddTorrentViewModel(torrentService: torrentService, syncService: syncService)
                    viewModel = vm
                    await vm.loadDefaults(modelContext: modelContext)
                    if let url = initialMagnetURL {
                        vm.magnetLink = url
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func addTorrentForm(vm: AddTorrentViewModel) -> some View {
        @Bindable var vm = vm
        Form {
            if let server = activeServer {
                Section {
                    LabeledContent("Server") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(server.displayName)
                            Text(server.hostURL)
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                        .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Destination")
                }
            }

            sourcePickerSection(vm: vm)

            Section {
                inputSection(vm: vm)
            }

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
            } header: {
                Text("Options")
            } footer: {
                Text("Leave Save Path blank to use the server default. Recent Paths helps you quickly reuse a location.")
            }

            if vm.isSubmitting {
                Section {
                    HStack {
                        ProgressView()
                        Text(submissionText)
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
            allowedContentTypes: [UTType(filenameExtension: "torrent") ?? .data]
        ) { result in
            if case .success(let url) = result {
                Task {
                    if let torrentFile = await Self.readTorrentFile(from: url) {
                        vm.torrentFileData = torrentFile.data
                        vm.torrentFileName = torrentFile.fileName
                        inputTab = .file
                    }
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        .padding(20)
        .frame(maxWidth: 760, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        #endif
    }

    private func magnetTextField(magnetLink: Binding<String>) -> some View {
        #if os(iOS)
        return TextField("magnet:?xt=urn:btih:...", text: magnetLink, axis: .vertical)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .lineLimit(3...6)
        #else
        return TextField("magnet:?xt=urn:btih:...", text: magnetLink, axis: .vertical)
            .autocorrectionDisabled()
            .lineLimit(3...6)
        #endif
    }

    @ViewBuilder
    private func sourcePickerSection(vm: AddTorrentViewModel) -> some View {
        @Bindable var vm = vm
        let footer = inputTab == .magnet
            ? "Paste a magnet link from Safari or another app."
            : "Choose a .torrent file to upload to your server."
        Section(footer: Text(footer)) {
            Picker("Source", selection: $inputTab) {
                Text("Magnet Link").tag(AddTorrentInputMode.magnet)
                Text("Torrent File").tag(AddTorrentInputMode.file)
            }
            .pickerStyle(.segmented)
            .onChange(of: inputTab) { _, newValue in
                if newValue == .magnet {
                    vm.torrentFileData = nil
                    vm.torrentFileName = nil
                } else {
                    vm.magnetLink = ""
                }
            }
        }
    }

    @ViewBuilder
    private func inputSection(vm: AddTorrentViewModel) -> some View {
        @Bindable var vm = vm
        switch inputTab {
        case .magnet:
            magnetTextField(magnetLink: $vm.magnetLink)
        case .file:
            if let fileName = vm.torrentFileName {
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
                    Label("Select .torrent File", systemImage: "doc.badge.plus")
                }
            }
        }
    }

    private var activeServer: ServerProfile? {
        activeServers.first
    }

    private var submissionText: String {
        if let server = activeServer {
            return "Sending to \(server.displayName)…"
        }
        return "Adding torrent…"
    }

    private struct SelectedTorrentFile: Sendable {
        let data: Data
        let fileName: String
    }

    private nonisolated static func readTorrentFile(from url: URL) async -> SelectedTorrentFile? {
        await Task.detached(priority: .userInitiated) {
            guard url.startAccessingSecurityScopedResource() else { return nil }
            defer { url.stopAccessingSecurityScopedResource() }

            guard let data = try? Data(contentsOf: url) else { return nil }
            return SelectedTorrentFile(data: data, fileName: url.lastPathComponent)
        }.value
    }
}
