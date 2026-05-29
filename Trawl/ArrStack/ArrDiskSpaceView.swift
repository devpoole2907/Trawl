import SwiftUI

struct ArrDiskSpaceView: View {
    @Environment(ArrServiceManager.self) private var serviceManager

    @State private var snapshots: [ArrDiskSpaceSnapshot] = []
    @State private var isLoading = false

    #if DEBUG
    init(previewSnapshots: [ArrDiskSpaceSnapshot] = [], isLoading: Bool = false) {
        _snapshots = State(initialValue: previewSnapshots)
        _isLoading = State(initialValue: isLoading)
    }
    #endif

    var body: some View {
        Group {
            if !hasConfiguredService {
                ContentUnavailableView(
                    "No Services Configured",
                    systemImage: "server.rack",
                    description: Text("Connect Sonarr or Radarr to inspect storage usage.")
                )
            } else if !hasConnectedService {
                ArrServicesConnectionStatusView(
                    services: diskSpaceServices,
                    title: "Services Unreachable",
                    message: "Unable to reach your configured Sonarr or Radarr servers."
                )
            } else if isLoading && snapshots.isEmpty {
                ProgressView("Loading disk space...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if snapshots.isEmpty {
                ContentUnavailableView(
                    "No Disk Data",
                    systemImage: "externaldrive.badge.questionmark",
                    description: Text("No disk space information is currently available from your services.")
                )
            } else {
                List {
                    if !sonarrSnapshots.isEmpty {
                        serviceSection(title: "Sonarr", snapshots: sonarrSnapshots)
                    }

                    if !radarrSnapshots.isEmpty {
                        serviceSection(title: "Radarr", snapshots: radarrSnapshots)
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #else
                .listStyle(.inset)
                #endif
                .scrollContentBackground(.hidden)
            }
        }
        .background(backgroundGradient)
        .navigationTitle("Disk Space")
        .task(id: reloadKey) {
            #if DEBUG
            if ArrPreviewRuntime.isActive { return }
            #endif
            await loadDiskSpace()
        }
        .refreshable {
            await loadDiskSpace()
        }
    }

    private var hasConfiguredService: Bool {
        serviceManager.hasSonarrInstance || serviceManager.hasRadarrInstance
    }

    private var diskSpaceServices: [ArrServiceType] {
        var services: [ArrServiceType] = []
        if serviceManager.hasSonarrInstance { services.append(.sonarr) }
        if serviceManager.hasRadarrInstance { services.append(.radarr) }
        return services
    }

    private var hasConnectedService: Bool {
        serviceManager.sonarrConnected || serviceManager.radarrConnected
    }

    private var reloadKey: String {
        "\(serviceManager.sonarrConnected)-\(serviceManager.radarrConnected)"
    }

    private var sonarrSnapshots: [ArrDiskSpaceSnapshot] {
        snapshots.filter { $0.serviceType == .sonarr }
    }

    private var radarrSnapshots: [ArrDiskSpaceSnapshot] {
        snapshots.filter { $0.serviceType == .radarr }
    }

    private func loadDiskSpace() async {
        isLoading = true

        async let sonarrDisks: [ArrDiskSpaceSnapshot] = loadDiskSpace(
            from: serviceManager.sonarrClient,
            serviceType: .sonarr
        )
        async let radarrDisks: [ArrDiskSpaceSnapshot] = loadDiskSpace(
            from: serviceManager.radarrClient,
            serviceType: .radarr
        )

        snapshots = await (sonarrDisks + radarrDisks)
        isLoading = false
    }

    private func loadDiskSpace(
        from client: ArrDiskSpaceViewProviding?,
        serviceType: ArrServiceType
    ) async -> [ArrDiskSpaceSnapshot] {
        guard let client else { return [] }

        do {
            return try await client.getDiskSpace().map {
                ArrDiskSpaceSnapshot(
                    serviceType: serviceType,
                    path: $0.path ?? "Unknown",
                    label: $0.label,
                    freeSpace: $0.freeSpace,
                    totalSpace: $0.totalSpace
                )
            }
        } catch {
            return []
        }
    }

    private var backgroundGradient: some View {
        ZStack {
            #if os(macOS)
            Color(nsColor: .windowBackgroundColor)
            #else
            Color(uiColor: .systemGroupedBackground)
            #endif
            LinearGradient(
                colors: [Color.teal.opacity(0.24), Color.clear],
                startPoint: .top,
                endPoint: .center
            )

            RadialGradient(
                colors: [Color.teal.opacity(0.18), Color.clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 260
            )
        }
        .ignoresSafeArea()
    }

    private func serviceSection(title: String, snapshots: [ArrDiskSpaceSnapshot]) -> some View {
        Section(title) {
            ForEach(snapshots) { snapshot in
                DiskSpaceRow(snapshot: snapshot)
            }
        }
    }
}

private struct DiskSpaceRow: View {
    let snapshot: ArrDiskSpaceSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(snapshot.label ?? "Storage")
                    .font(.subheadline.weight(.medium))

                Spacer(minLength: 12)

                if let freeSpace = snapshot.freeSpace {
                    Text("\(ByteFormatter.format(bytes: freeSpace)) free")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            Text(snapshot.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let totalSpace = snapshot.totalSpace, totalSpace > 0, let freeSpace = snapshot.freeSpace {
                let usedSpace = totalSpace - freeSpace
                ProgressView(value: Double(usedSpace), total: Double(totalSpace))
                    .tint(freeSpace > totalSpace / 5 ? .teal : .orange)

                HStack {
                    Text("Used \(ByteFormatter.format(bytes: usedSpace))")
                    Spacer()
                    Text("Total \(ByteFormatter.format(bytes: totalSpace))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private protocol ArrDiskSpaceViewProviding: Sendable {
    func getDiskSpace() async throws -> [ArrDiskSpace]
}

extension SonarrAPIClient: ArrDiskSpaceViewProviding {}
extension RadarrAPIClient: ArrDiskSpaceViewProviding {}

#if DEBUG
#Preview("Disk Space - Loaded") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrDiskSpaceView(previewSnapshots: ArrDiskSpaceSnapshot.previewList)
        }
    }
}

#Preview("Disk Space - Empty") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrDiskSpaceView()
        }
    }
}

#Preview("Disk Space - Loading") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrDiskSpaceView(isLoading: true)
        }
    }
}

#Preview("Disk Space - Connection Issue") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.sonarrConnectionError("Unable to reach 192.168.1.50:8989"))) {
        NavigationStack {
            ArrDiskSpaceView()
        }
    }
}
#endif
