import SwiftUI
import SwiftData

// MARK: - Location Browser

struct ArrManualImportView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Query private var allProfiles: [ArrServiceProfile]

    @State private var selectedService: ArrServiceType = .sonarr
    @State private var showAddLocation = false

    private var availableServices: [ArrServiceType] {
        var services: [ArrServiceType] = []
        if serviceManager.hasSonarrInstance { services.append(.sonarr) }
        if serviceManager.hasRadarrInstance { services.append(.radarr) }
        return services
    }

    private var rootFolders: [ArrRootFolder] {
        selectedService == .sonarr ? serviceManager.sonarrRootFolders : serviceManager.radarrRootFolders
    }

    private var currentProfile: ArrServiceProfile? {
        let activeProfileID: UUID?
        switch selectedService {
        case .sonarr:
            activeProfileID = serviceManager.activeSonarrProfileID
        case .radarr:
            activeProfileID = serviceManager.activeRadarrProfileID
        case .prowlarr:
            activeProfileID = nil
        }

        if let activeProfileID, let profile = allProfiles.first(where: { $0.id == activeProfileID }) {
            return profile
        }
        return allProfiles.first { $0.resolvedServiceType == selectedService }
    }

    private var customFolders: [String] {
        currentProfile?.importFolders ?? []
    }

    var body: some View {
        Group {
            if availableServices.isEmpty {
                emptyState
            } else {
                listContent
            }
        }
        .navigationTitle("Manual Import")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Services Configured", systemImage: "tray.and.arrow.down")
        } description: {
            Text("Add a Sonarr or Radarr server in Settings to use Manual Import.")
        }
    }

    private var listContent: some View {
        List {
            if availableServices.count > 1 {
                Section {
                    Picker("Service", selection: $selectedService.animation(.spring(response: 0.35, dampingFraction: 0.85))) {
                        ForEach(availableServices) { service in
                            Text(service.displayName).tag(service)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Service")
                }
            }

            if !rootFolders.isEmpty {
                Section {
                    ForEach(rootFolders) { folder in
                        NavigationLink(value: MoreDestination.manualImportScan(path: folder.path, service: selectedService)) {
                            locationRow(
                                icon: "internaldrive",
                                title: folder.path,
                                subtitle: "Library Root",
                                tint: .secondary
                            )
                        }
                    }
                } header: {
                    Text("Library Roots")
                }
            }

            Section {
                if customFolders.isEmpty {
                    Text("No saved locations")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(customFolders, id: \.self) { path in
                        NavigationLink(value: MoreDestination.manualImportScan(path: path, service: selectedService)) {
                            locationRow(
                                icon: "folder",
                                title: path,
                                subtitle: "Custom",
                                tint: .blue
                            )
                        }
                    }
                    .onDelete(perform: removeBookmarks)
                }
            } header: {
                Text("Your Locations")
            } footer: {
                if customFolders.isEmpty {
                    Text("Save the paths to your download directories so you can quickly scan them for unmapped files.")
                }
            }

            Section {
                Button {
                    showAddLocation = true
                } label: {
                    Label("Add Custom Path", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.medium))
                }
            }
        }
        .listStyle(.insetGrouped)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: selectedService)
        .sheet(isPresented: $showAddLocation) {
            AddImportLocationSheet(service: selectedService) { path in
                addBookmark(path: path)
            }
        }
        .onAppear {
            if !availableServices.contains(selectedService), let first = availableServices.first {
                selectedService = first
            }
        }
    }

    private func locationRow(icon: String, title: String, subtitle: String, tint: Color) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(tint.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func addBookmark(path: String) {
        guard let profile = currentProfile else { return }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !profile.importFolders.contains(trimmed) else { return }

        guard isAbsoluteImportPath(trimmed) else { return }

        withAnimation {
            profile.importFolders.append(trimmed)
        }
    }

    private func removeBookmarks(at offsets: IndexSet) {
        guard let profile = currentProfile else { return }
        withAnimation {
            profile.importFolders.remove(atOffsets: offsets)
        }
    }
}

// MARK: - Add Location Sheet

struct AddImportLocationSheet: View {
    let service: ArrServiceType
    let onAdd: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Absolute path on server", text: $path)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } footer: {
                    Text("Example: /downloads/completed")
                }

                Section {
                    Text("This location will be saved for \(service.displayName).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Add Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }

                        guard isAbsoluteImportPath(trimmed) else { return }

                        onAdd(trimmed)
                        dismiss()
                    }
                    .disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Scan View Model

@Observable
@MainActor
fileprivate final class ManualImportScanViewModel {
    let path: String
    let service: ArrServiceType
    let serviceManager: ArrServiceManager

    var isLoading = false
    var importableFiles: [ManualImportItem] = []
    var selectedFiles: Set<String> = []

    init(path: String, service: ArrServiceType, serviceManager: ArrServiceManager) {
        self.path = path
        self.service = service
        self.serviceManager = serviceManager
    }

    var folderName: String {
        (path as NSString).lastPathComponent
    }

    var allSelected: Bool {
        !importableFiles.isEmpty && selectedFiles.count == importableFiles.count
    }

    func toggleSelectAll() {
        if allSelected {
            selectedFiles.removeAll()
        } else {
            selectedFiles = Set(importableFiles.map(\.id))
        }
    }

    func toggleFile(_ id: String) {
        if selectedFiles.contains(id) {
            selectedFiles.remove(id)
        } else {
            selectedFiles.insert(id)
        }
    }

    func loadFiles() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let jsonValues = try await getManualImport(folder: path)
            importableFiles = jsonValues.compactMap { ManualImportItem(json: $0) }
        } catch is CancellationError {
            importableFiles = []
        } catch {
            InAppNotificationCenter.shared.showError(title: "Scan Failed", message: error.localizedDescription)
            importableFiles = []
        }
    }

    func performImport() async {
        let availableIDs = Set(importableFiles.map(\.id))
        selectedFiles = selectedFiles.intersection(availableIDs)

        guard !selectedFiles.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        let filesToImport = importableFiles.filter { selectedFiles.contains($0.id) }.map { $0.originalJSON }

        do {
            try await manualImport(files: filesToImport)
            InAppNotificationCenter.shared.showSuccess(title: "Import Started", message: "Import command sent to \(service.displayName).")
            selectedFiles = []
            await loadFiles()
        } catch is CancellationError {
            // Task cancelled, do nothing
        } catch {
            InAppNotificationCenter.shared.showError(title: "Import Failed", message: error.localizedDescription)
        }
    }

    private func getManualImport(folder: String) async throws -> [JSONValue] {
        switch service {
        case .sonarr:
            guard let client = serviceManager.sonarrClient else {
                throw ManualImportServiceClientUnavailableError(service: service)
            }
            return try await client.getManualImport(folder: folder)
        case .radarr:
            guard let client = serviceManager.radarrClient else {
                throw ManualImportServiceClientUnavailableError(service: service)
            }
            return try await client.getManualImport(folder: folder)
        case .prowlarr:
            throw ManualImportServiceClientUnavailableError(service: service)
        }
    }

    private func manualImport(files: [JSONValue]) async throws {
        switch service {
        case .sonarr:
            guard let client = serviceManager.sonarrClient else {
                throw ManualImportServiceClientUnavailableError(service: service)
            }
            try await client.manualImport(files: files)
        case .radarr:
            guard let client = serviceManager.radarrClient else {
                throw ManualImportServiceClientUnavailableError(service: service)
            }
            try await client.manualImport(files: files)
        case .prowlarr:
            throw ManualImportServiceClientUnavailableError(service: service)
        }
    }
}

private struct ManualImportServiceClientUnavailableError: LocalizedError {
    let service: ArrServiceType

    var errorDescription: String? {
        "\(service.displayName) client is not available."
    }
}

private func isAbsoluteImportPath(_ path: String) -> Bool {
    path.hasPrefix("/") || path.hasPrefix("\\\\") || isWindowsDrivePath(path)
}

private func isWindowsDrivePath(_ path: String) -> Bool {
    guard path.count >= 3 else { return false }
    let characters = Array(path.prefix(3))
    let drive = characters[0]
    let separator = characters[2]

    return drive.isASCII && drive.isLetter && characters[1] == ":" && (separator == "\\" || separator == "/")
}

// MARK: - Scan View

struct ManualImportScanView: View {
    @State private var viewModel: ManualImportScanViewModel

    init(path: String, service: ArrServiceType, serviceManager: ArrServiceManager) {
        _viewModel = State(wrappedValue: ManualImportScanViewModel(path: path, service: service, serviceManager: serviceManager))
    }

    var body: some View {
        List {
            if viewModel.isLoading && viewModel.importableFiles.isEmpty {
                Section {
                    HStack {
                        Spacer()
                        ProgressView("Scanning for files…")
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
            } else if viewModel.importableFiles.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Importable Files",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("No unmapped files found in this directory.")
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(viewModel.importableFiles) { item in
                        ManualImportRow(
                            item: item,
                            isSelected: viewModel.selectedFiles.contains(item.id)
                        ) {
                            withAnimation(.snappy) {
                                viewModel.toggleFile(item.id)
                            }
                        }
                    }
                } header: {
                    Text("Found Files")
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(viewModel.folderName)
        .navigationSubtitle(navigationSubtitleText)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            await viewModel.loadFiles()
        }
        .toolbar {
            if !viewModel.importableFiles.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    Button(viewModel.allSelected ? "Deselect" : "Select All") {
                        withAnimation(.snappy) {
                            viewModel.toggleSelectAll()
                        }
                    }
                    .font(.subheadline)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.performImport() }
                    } label: {
                        if viewModel.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Import")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(viewModel.isLoading || viewModel.selectedFiles.isEmpty)
                }
            }
        }
        .task {
            if viewModel.importableFiles.isEmpty {
                await viewModel.loadFiles()
            }
        }
    }

    private var navigationSubtitleText: String {
        if viewModel.selectedFiles.isEmpty {
            return viewModel.path
        } else {
            let count = viewModel.selectedFiles.count
            return "\(count) file\(count == 1 ? "" : "s") selected"
        }
    }
}

// MARK: - Models

fileprivate struct ManualImportItem: Identifiable {
    let id: String
    let path: String
    let fileName: String
    let size: Int64
    let originalJSON: JSONValue

    init?(json: JSONValue) {
        guard case .object(let dict) = json else { return nil }

        if case .string(let p) = dict["path"] {
            self.path = p
            self.id = p
        } else {
            return nil
        }

        if case .string(let n) = dict["name"] {
            self.fileName = n
        } else if case .string(let fn) = dict["fileName"] {
            self.fileName = fn
        } else {
            self.fileName = (path as NSString).lastPathComponent
        }

        if case .number(let s) = dict["size"] {
            self.size = Int64(s)
        } else {
            self.size = 0
        }

        self.originalJSON = json
    }
}

fileprivate struct ManualImportRow: View {
    let item: ManualImportItem
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 14) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .font(.title3)
                    .contentTransition(.symbolEffect(.replace))

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.fileName)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(ByteFormatter.format(bytes: item.size))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}
