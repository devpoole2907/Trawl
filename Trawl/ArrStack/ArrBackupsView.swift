import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

struct ArrBackupsView: View {
    @Environment(ArrServiceManager.self) private var serviceManager

    @State private var selectedService: ArrServiceType = .sonarr
    @State private var states: [ArrServiceType: BackupViewState] = [:]
    @State private var unavailable: Set<ArrServiceType> = []
    @State private var sortOrder: BackupSortOrder = .newestFirst
    @State private var servicePendingBackupCreation: ArrServiceType?
    @State private var backupPendingDelete: PendingBackupDelete?
    @State private var backupPendingRestore: PendingBackupDelete?
    @State private var preparingShareID: String?
    @State private var showingFilePicker = false

    private struct BackupViewState {
        var backups: [ArrBackup] = []
        var isLoading = false
        var isCreating = false
        var isUploading = false
        var error: String?
    }

    private struct PendingBackupDelete: Identifiable, Sendable {
        let backup: ArrBackup
        let service: ArrServiceType

        var id: String { "\(service.rawValue)-\(backup.id)" }
    }

    private enum BackupSortOrder: String, CaseIterable, Identifiable {
        case newestFirst = "Newest First"
        case oldestFirst = "Oldest First"
        case nameAscending = "Name A-Z"
        case nameDescending = "Name Z-A"
        case largestFirst = "Largest First"
        case smallestFirst = "Smallest First"

        var id: Self { self }

        var systemImage: String {
            switch self {
            case .newestFirst: "clock.arrow.circlepath"
            case .oldestFirst: "clock"
            case .nameAscending: "textformat.abc"
            case .nameDescending: "textformat.abc.dottedunderline"
            case .largestFirst: "arrow.down.to.line.compact"
            case .smallestFirst: "arrow.up.to.line.compact"
            }
        }
    }

    private var availableServices: [ArrServiceType] {
        var services: [ArrServiceType] = []
        if serviceManager.hasSonarrInstance { services.append(.sonarr) }
        if serviceManager.hasRadarrInstance { services.append(.radarr) }
        if serviceManager.hasProwlarrInstance { services.append(.prowlarr) }
        if serviceManager.hasBazarrInstance { services.append(.bazarr) }
        return services
    }

    var body: some View {
        Group {
            if availableServices.isEmpty {
                ContentUnavailableView(
                    "No Services Configured",
                    systemImage: "externaldrive.fill",
                    description: Text("Add a Sonarr, Radarr, Prowlarr, or Bazarr server in Settings to manage backups.")
                )
            } else if unavailable.contains(selectedService) {
                ContentUnavailableView(
                    "Service Unreachable",
                    systemImage: "network.slash",
                    description: Text("\(selectedService.displayName) is configured but currently unreachable.")
                )
            } else if let state = states[selectedService] {
                backupList(state: state, service: selectedService)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Backups")
        .moreDestinationBackground(.backups)
        .toolbar {
            ToolbarItemGroup(placement: platformTopBarTrailingPlacement) {
                Menu {
                    ForEach(BackupSortOrder.allCases) { order in
                        Button {
                            withAnimation {
                                sortOrder = order
                            }
                        } label: {
                            if sortOrder == order {
                                Label(order.rawValue, systemImage: "checkmark")
                            } else {
                                Label(order.rawValue, systemImage: order.systemImage)
                            }
                        }
                    }
                } label: {
                    Label("Sort", systemImage: sortOrder.systemImage)
                }
                .disabled(states[selectedService]?.backups.isEmpty != false)

                if selectedService.supportsBackupUpload {
                    let isUploading = states[selectedService]?.isUploading == true
                    if isUploading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Upload Backup", systemImage: "arrow.up.doc") {
                            showingFilePicker = true
                        }
                        .disabled(availableServices.isEmpty)
                    }
                }

                let isCreating = states[selectedService]?.isCreating == true
                if isCreating {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Create Backup", systemImage: "externaldrive.badge.plus") {
                        servicePendingBackupCreation = selectedService
                    }
                    .disabled(availableServices.isEmpty)
                }
            }
        }
        .alert("Create Backup?", isPresented: Binding(
            get: { servicePendingBackupCreation != nil },
            set: { if !$0 { servicePendingBackupCreation = nil } }
        )) {
            Button("Create Backup") {
                guard let servicePendingBackupCreation else { return }
                self.servicePendingBackupCreation = nil
                Task { await createBackup(for: servicePendingBackupCreation) }
            }
            Button("Cancel", role: .cancel) {
                servicePendingBackupCreation = nil
            }
        } message: {
            if let servicePendingBackupCreation {
                Text("Create a manual backup for \(servicePendingBackupCreation.displayName)?")
            }
        }
        .alert("Delete Backup?", isPresented: Binding(
            get: { backupPendingDelete != nil },
            set: { if !$0 { backupPendingDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                guard let backupPendingDelete else { return }
                self.backupPendingDelete = nil
                Task { await deleteBackup(backupPendingDelete) }
            }
            Button("Cancel", role: .cancel) {
                backupPendingDelete = nil
            }
        } message: {
            if let backupPendingDelete {
                Text("Delete \"\(backupPendingDelete.backup.name)\" from \(backupPendingDelete.service.displayName)?")
            }
        }
        .alert("Restore Backup?", isPresented: Binding(
            get: { backupPendingRestore != nil },
            set: { if !$0 { backupPendingRestore = nil } }
        )) {
            Button("Restore", role: .destructive) {
                guard let backupPendingRestore else { return }
                self.backupPendingRestore = nil
                Task { await restoreBackup(backupPendingRestore) }
            }
            Button("Cancel", role: .cancel) {
                backupPendingRestore = nil
            }
        } message: {
            if let backupPendingRestore {
                Text("Restore \"\(backupPendingRestore.backup.name)\" to \(backupPendingRestore.service.displayName)? The service may restart while the backup is applied.")
            }
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.zip]
        ) { result in
            let service = selectedService
            switch result {
            case .success(let url):
                Task { await uploadBackup(url: url, for: service) }
            case .failure(let error):
                InAppNotificationCenter.shared.showError(
                    title: "File Selection Failed",
                    message: error.localizedDescription
                )
            }
        }
        .safeAreaInset(edge: .top) {
            TrawlSegmentBar(
                "Service",
                selection: Binding(
                    get: { selectedService },
                    set: { newService in withAnimation { selectedService = newService } }
                ),
                items: availableServices.map(\.segmentBarItem),
                alignment: .leading
            )
        }
        .loadServicesPeriodically(availableServices) { service in
            await loadService(service)
        }
        .onAppear {
            if !availableServices.contains(selectedService), let first = availableServices.first {
                selectedService = first
            }
        }
    }

    // MARK: - List

    @ViewBuilder
    private func backupList(state: BackupViewState, service: ArrServiceType) -> some View {
        List {
            if let error = state.error, state.backups.isEmpty {
                Section {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                }
            }

            if state.isLoading && state.backups.isEmpty {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else if state.backups.isEmpty {
                ContentUnavailableView(
                    "No Backups",
                    systemImage: "externaldrive",
                    description: Text("No backups found for \(service.displayName).")
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(sortedBackups(state.backups), id: \.id) { backup in
                        if let client = client(for: service) {
                            let shareID = sharePreparationID(for: backup, service: service)
                            let shareItem = ArrBackupShareItem(backup: backup, service: service, client: client) { isPreparing in
                                setSharePreparation(isPreparing, for: shareID)
                            }
                            ShareLink(
                                item: shareItem,
                                preview: SharePreview(backup.name, icon: Image(systemName: "externaldrive"))
                            ) {
                                ArrBackupRow(
                                    backup: backup,
                                    service: service,
                                    isPreparingShare: preparingShareID == shareID
                                )
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            .simultaneousGesture(TapGesture().onEnded {
                                setSharePreparation(true, for: shareID)
                            })
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    backupPendingDelete = PendingBackupDelete(backup: backup, service: service)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }

                                Button {
                                    backupPendingRestore = PendingBackupDelete(backup: backup, service: service)
                                } label: {
                                    Label("Restore", systemImage: "arrow.counterclockwise")
                                }
                                .tint(.orange)
                            }
                            .contextMenu {
                                ShareLink(
                                    item: shareItem,
                                    preview: SharePreview(backup.name, icon: Image(systemName: "externaldrive"))
                                ) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }

                                Button("Restore", systemImage: "arrow.counterclockwise") {
                                    backupPendingRestore = PendingBackupDelete(backup: backup, service: service)
                                }

                                Divider()

                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    backupPendingDelete = PendingBackupDelete(backup: backup, service: service)
                                }
                            }
                        } else {
                            ArrBackupRow(backup: backup, service: service)
                                .contentShape(Rectangle())
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .refreshable { await loadService(service) }
        .animation(.default, value: sortedBackups(state.backups).map(\.id))
    }

    // MARK: - Load

    @MainActor
    private func loadService(_ service: ArrServiceType) async {
        guard let client = client(for: service) else { unavailable.insert(service); return }
        states[service, default: BackupViewState()].isLoading = true
        states[service]?.error = nil
        do {
            let backups = try await client.getBackups()
            withAnimation {
                states[service, default: BackupViewState()].backups = backups
                states[service]?.isLoading = false
            }
        } catch {
            states[service]?.error = error.localizedDescription
            states[service]?.isLoading = false
        }
    }

    @MainActor
    private func createBackup(for service: ArrServiceType) async {
        guard let client = client(for: service) else { return }
        states[service]?.isCreating = true
        do {
            try await client.createBackup()
            try? await Task.sleep(for: .seconds(3))
            await loadService(service)
        } catch {
            InAppNotificationCenter.shared.showError(
                title: "Backup Failed",
                message: error.localizedDescription
            )
        }
        states[service]?.isCreating = false
    }

    @MainActor
    private func uploadBackup(url: URL, for service: ArrServiceType) async {
        guard let client = client(for: service) else { return }
        states[service]?.isUploading = true
        do {
            let filename = url.lastPathComponent
            let data = try await Task.detached(priority: .userInitiated) {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                return try Data(contentsOf: url)
            }.value
            try await client.uploadBackup(data: data, filename: filename)
            InAppNotificationCenter.shared.showSuccess(
                title: "Restore Started",
                message: "\(service.displayName) is restoring from the uploaded backup."
            )
            try? await Task.sleep(for: .seconds(3))
            await loadService(service)
        } catch {
            InAppNotificationCenter.shared.showError(
                title: "Upload Failed",
                message: error.localizedDescription
            )
        }
        states[service]?.isUploading = false
    }

    @MainActor
    private func restoreBackup(_ pendingRestore: PendingBackupDelete) async {
        guard let client = client(for: pendingRestore.service) else { return }
        do {
            try await client.restoreBackup(pendingRestore.backup)
            InAppNotificationCenter.shared.showSuccess(
                title: "Restore Started",
                message: "\(pendingRestore.service.displayName) is restoring \"\(pendingRestore.backup.name)\"."
            )
        } catch {
            InAppNotificationCenter.shared.showError(
                title: "Restore Failed",
                message: error.localizedDescription
            )
        }
    }

    @MainActor
    private func deleteBackup(_ pendingDelete: PendingBackupDelete) async {
        guard let client = client(for: pendingDelete.service) else { return }
        do {
            try await client.deleteBackup(pendingDelete.backup)
            withAnimation {
                states[pendingDelete.service]?.backups.removeAll { $0.id == pendingDelete.backup.id }
            }
            InAppNotificationCenter.shared.showSuccess(
                title: "Backup Deleted",
                message: "\"\(pendingDelete.backup.name)\" was removed from \(pendingDelete.service.displayName)."
            )
        } catch {
            InAppNotificationCenter.shared.showError(
                title: "Delete Failed",
                message: error.localizedDescription
            )
        }
    }

    private func sortedBackups(_ backups: [ArrBackup]) -> [ArrBackup] {
        backups.sorted { lhs, rhs in
            switch sortOrder {
            case .newestFirst:
                backupTime(lhs, isOrderedBefore: rhs, newestFirst: true)
            case .oldestFirst:
                backupTime(lhs, isOrderedBefore: rhs, newestFirst: false)
            case .nameAscending:
                backupName(lhs, isOrderedBefore: rhs, ascending: true)
            case .nameDescending:
                backupName(lhs, isOrderedBefore: rhs, ascending: false)
            case .largestFirst:
                backupSize(lhs, isOrderedBefore: rhs, largestFirst: true)
            case .smallestFirst:
                backupSize(lhs, isOrderedBefore: rhs, largestFirst: false)
            }
        }
    }

    private func backupTime(_ lhs: ArrBackup, isOrderedBefore rhs: ArrBackup, newestFirst: Bool) -> Bool {
        if let lhsDate = backupDate(lhs), let rhsDate = backupDate(rhs), lhsDate != rhsDate {
            return newestFirst ? lhsDate > rhsDate : lhsDate < rhsDate
        }
        if lhs.time == rhs.time {
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        return newestFirst ? lhs.time > rhs.time : lhs.time < rhs.time
    }

    private func backupDate(_ backup: ArrBackup) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: backup.time) {
            return date
        }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: backup.time)
    }

    private func backupName(_ lhs: ArrBackup, isOrderedBefore rhs: ArrBackup, ascending: Bool) -> Bool {
        let comparison = lhs.name.localizedStandardCompare(rhs.name)
        if comparison == .orderedSame {
            return backupTime(lhs, isOrderedBefore: rhs, newestFirst: true)
        }
        return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
    }

    private func backupSize(_ lhs: ArrBackup, isOrderedBefore rhs: ArrBackup, largestFirst: Bool) -> Bool {
        let lhsSize = lhs.size ?? (largestFirst ? -1 : Int.max)
        let rhsSize = rhs.size ?? (largestFirst ? -1 : Int.max)
        if lhsSize == rhsSize {
            return backupTime(lhs, isOrderedBefore: rhs, newestFirst: true)
        }
        return largestFirst ? lhsSize > rhsSize : lhsSize < rhsSize
    }

    private func client(for service: ArrServiceType) -> (any SharedArrClient)? {
        switch service {
        case .sonarr: serviceManager.sonarrClient
        case .radarr: serviceManager.radarrClient
        case .prowlarr: serviceManager.prowlarrClient
        case .bazarr: serviceManager.activeBazarrEntry?.client
        }
    }

    private func sharePreparationID(for backup: ArrBackup, service: ArrServiceType) -> String {
        "\(service.rawValue)-\(backup.id)"
    }

    @MainActor
    private func setSharePreparation(_ isPreparing: Bool, for shareID: String) {
        withAnimation(.default) {
            if isPreparing {
                preparingShareID = shareID
            } else if preparingShareID == shareID {
                preparingShareID = nil
            }
        }
    }
}

private extension ArrServiceType {
    var supportsBackupUpload: Bool { self != .bazarr }
}

private struct ArrBackupShareItem: Transferable, Sendable {
    let backup: ArrBackup
    let service: ArrServiceType
    let client: any SharedArrClient
    let onPreparationChanged: @MainActor @Sendable (Bool) -> Void

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { item in
            await item.onPreparationChanged(true)
            do {
                let data = try await item.client.downloadBackup(item.backup)
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("TrawlBackupShare-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

                let fileURL = directory.appendingPathComponent(item.fileName)
                try data.write(to: fileURL, options: .atomic)
                await item.onPreparationChanged(false)
                return SentTransferredFile(fileURL)
            } catch {
                await item.onPreparationChanged(false)
                throw error
            }
        }
    }

    private var fileName: String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleanedName = backup.name
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = cleanedName.isEmpty ? "\(service.displayName)-Backup-\(backup.id)" : cleanedName
        return baseName.lowercased().hasSuffix(".zip") ? baseName : "\(baseName).zip"
    }
}

// MARK: - Backup Row

private struct ArrBackupRow: View {
    let backup: ArrBackup
    let service: ArrServiceType
    let isPreparingShare: Bool

    init(backup: ArrBackup, service: ArrServiceType, isPreparingShare: Bool = false) {
        self.backup = backup
        self.service = service
        self.isPreparingShare = isPreparingShare
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: typeIcon)
                    .font(.caption2)
                    .foregroundStyle(typeColor)
                Text(typeLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let size = backup.size {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if isPreparingShare {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                        .accessibilityLabel("Preparing backup share")
                }
            }
            Text(backup.name)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(2)
            if let date = formattedDate {
                Text(date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var typeLabel: String {
        switch backup.type.lowercased() {
        case "manual": "Manual"
        case "scheduled": "Scheduled"
        case "update": "Pre-Update"
        default: backup.type.capitalized
        }
    }

    private var typeIcon: String {
        switch backup.type.lowercased() {
        case "manual": "hand.tap"
        case "scheduled": "clock"
        case "update": "arrow.down.app"
        default: "externaldrive"
        }
    }

    private var typeColor: Color {
        switch backup.type.lowercased() {
        case "manual": service.serviceIdentity.brandColor
        case "scheduled": .teal
        case "update": .green
        default: .secondary
        }
    }

    private var formattedDate: String? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: backup.time) {
            return date.formatted(date: .long, time: .shortened)
        }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: backup.time) {
            return date.formatted(date: .long, time: .shortened)
        }
        return backup.time
    }
}
