import SwiftUI

struct ArrBackupsView: View {
    @Environment(ArrServiceManager.self) private var serviceManager

    @State private var selectedService: ArrServiceType = .sonarr
    @State private var states: [ArrServiceType: BackupViewState] = [:]
    @State private var unavailable: Set<ArrServiceType> = []

    private struct BackupViewState {
        var backups: [ArrBackup] = []
        var isLoading = false
        var isCreating = false
        var error: String?
    }

    private var availableServices: [ArrServiceType] {
        var services: [ArrServiceType] = []
        if serviceManager.hasSonarrInstance { services.append(.sonarr) }
        if serviceManager.hasRadarrInstance { services.append(.radarr) }
        if serviceManager.hasProwlarrInstance { services.append(.prowlarr) }
        return services
    }

    var body: some View {
        Group {
            if availableServices.isEmpty {
                ContentUnavailableView(
                    "No Services Configured",
                    systemImage: "externaldrive.fill",
                    description: Text("Add a Sonarr, Radarr, or Prowlarr server in Settings to manage backups.")
                )
            } else if unavailable.contains(selectedService) {
                ContentUnavailableView(
                    "Service Unreachable",
                    systemImage: "network.slash",
                    description: Text("\(selectedService.displayName) is configured but currently unreachable.")
                )
            } else if let state = states[selectedService] {
                backupList(state: state, service: selectedService)
                    .id(selectedService)
                    .transition(.opacity)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }
        }
        .animation(.default, value: selectedService)
        .navigationTitle("Backups")
        .moreDestinationBackground(.mediaManagement)
        .toolbar {
            ToolbarItem(placement: platformTopBarTrailingPlacement) {
                let isCreating = states[selectedService]?.isCreating == true
                if isCreating {
                    ProgressView().controlSize(.small)
                } else {
                    Menu {
                        Button("Create Backup", systemImage: "externaldrive.badge.plus") {
                            let service = selectedService
                            Task { await createBackup(for: service) }
                        }
                    } label: {
                        Image(systemName: "externaldrive.badge.plus")
                    }
                    .disabled(availableServices.isEmpty)
                }
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
                    ForEach(state.backups) { backup in
                        ArrBackupRow(backup: backup, service: service)
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
                states[service, default: BackupViewState()].backups = backups.sorted { $0.time > $1.time }
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
            _ = try await client.postCommand(name: "Backup")
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

    private func client(for service: ArrServiceType) -> (any SharedArrClient)? {
        switch service {
        case .sonarr: serviceManager.sonarrClient
        case .radarr: serviceManager.radarrClient
        case .prowlarr: serviceManager.prowlarrClient
        case .bazarr: nil
        }
    }
}

// MARK: - Backup Row

private struct ArrBackupRow: View {
    let backup: ArrBackup
    let service: ArrServiceType

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
