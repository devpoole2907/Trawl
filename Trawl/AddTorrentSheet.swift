import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct AddTorrentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncService.self) private var syncService
    @Environment(TorrentService.self) private var torrentService
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
            // Input mode picker
            Section {
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

            // Input section
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

            // Options
            Section("Options") {
                HStack {
                    Text("Save Path")
                    Spacer()
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
                            .font(.caption)
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
            }

            // Status
            if vm.isSubmitting {
                Section {
                    HStack {
                        ProgressView()
                        Text("Adding torrent...")
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
}
