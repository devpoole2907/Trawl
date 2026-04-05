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
            .navigationBarTitleDisplayMode(.inline)
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
            .task {
                if viewModel == nil {
                    let vm = AddTorrentViewModel(torrentService: torrentService, syncService: syncService)
                    viewModel = vm
                    await vm.loadDefaults(modelContext: modelContext)
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

            Section(footer: Text(inputTab == .magnet ? "Paste a magnet link from Safari or another app." : "Choose a .torrent file to upload to your server.")) {
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

            Section {
                switch inputTab {
                case .magnet:
                    TextField("magnet:?xt=urn:btih:...", text: $vm.magnetLink, axis: .vertical)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(3...6)

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

            Section {
                LabeledContent("Save Path") {
                    TextField("Default", text: $vm.savePath)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
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
        .sheet(isPresented: $showFilePicker) {
            DocumentPicker(contentTypes: [UTType(filenameExtension: "torrent") ?? .data]) { url in
                guard url.startAccessingSecurityScopedResource() else { return }
                defer { url.stopAccessingSecurityScopedResource() }
                if let data = try? Data(contentsOf: url) {
                    vm.torrentFileData = data
                    vm.torrentFileName = url.lastPathComponent
                    inputTab = .file
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
}
