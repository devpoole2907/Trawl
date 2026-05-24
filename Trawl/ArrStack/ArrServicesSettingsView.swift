import SwiftUI
import SwiftData

struct ArrServicesSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ArrServiceManager.self) private var serviceManager
    @Query private var profiles: [ArrServiceProfile]
    @State private var showAddSheet = false

    var body: some View {
        List {
            Section("Connected Services") {
                if profiles.isEmpty {
                    Text("No services configured. Tap + to add Sonarr, Radarr, Prowlarr, or Bazarr.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(profiles) { profile in
                        ServiceProfileRow(
                            profile: profile,
                            isConnected: isConnected(profile)
                        )
                    }
                    .onDelete(perform: deleteProfiles)
                }
            }

            Section {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Service", systemImage: "plus.circle")
                }
            }

            Section("Status") {
                ServiceStatusRow(name: "Sonarr", icon: "tv", connected: serviceManager.sonarrConnected)
                ServiceStatusRow(name: "Radarr", icon: "film", connected: serviceManager.radarrConnected)
                ServiceStatusRow(name: "Prowlarr", icon: "magnifyingglass.circle", connected: serviceManager.prowlarrConnected)
                ServiceStatusRow(name: "Bazarr", icon: "captions.bubble", connected: serviceManager.hasAnyConnectedBazarrInstance)
            }

            if !serviceManager.connectionErrors.isEmpty {
                Section("Errors") {
                    ForEach(serviceManager.connectionErrors.sorted(by: { $0.key < $1.key }), id: \.key) { _, error in
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle("Arr Services")
        .sheet(isPresented: $showAddSheet) {
            ArrSetupSheet(onComplete: {
                Task { await serviceManager.refreshConfiguration() }
            })
            .environment(serviceManager)
        }
    }

    private func isConnected(_ profile: ArrServiceProfile) -> Bool {
        guard let serviceType = profile.resolvedServiceType else { return false }
        return serviceManager.isConnected(serviceType, profileID: profile.id)
    }

    private func deleteProfiles(at offsets: IndexSet) {
        for index in offsets {
            let profile = profiles[index]
            Task {
                let vm = ArrSetupViewModel(serviceManager: serviceManager)
                await vm.deleteProfile(profile, modelContext: modelContext)
            }
        }
    }
}

private struct ServiceStatusRow: View {
    let name: String
    let icon: String
    let connected: Bool

    var body: some View {
        HStack {
            Label(name, systemImage: icon)
            Spacer()
            Image(systemName: connected ? "circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(connected ? .green : .red)
            Text(connected ? "Connected" : "Disconnected")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ServiceProfileRow: View {
    let profile: ArrServiceProfile
    let isConnected: Bool

    var body: some View {
        HStack {
            if let serviceType = profile.resolvedServiceType {
                Image(systemName: serviceType.systemImage)
                    .foregroundStyle(iconColor)
                    .frame(width: 24)
            } else {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName)
                    .font(.subheadline)
                Text(profile.hostURL)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Image(systemName: isConnected ? "circle.fill" : "circle")
                    .font(.caption2)
                    .foregroundStyle(isConnected ? .green : .red)
                if let version = profile.apiVersion {
                    Text("v\(version)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var iconColor: Color {
        guard let serviceType = profile.resolvedServiceType else { return .secondary }
        switch serviceType {
        case .sonarr: return .blue
        case .radarr: return .purple
        case .prowlarr: return .yellow
        case .bazarr: return .teal
        }
    }
}

#if DEBUG
#Preview("Services - Configured") {
    PreviewHost(profiles: .allServices, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrServicesSettingsView()
        }
    }
}

#Preview("Services - Empty") {
    PreviewHost(profiles: .empty, arr: .preview(.noneConfigured)) {
        NavigationStack {
            ArrServicesSettingsView()
        }
    }
}
#endif
