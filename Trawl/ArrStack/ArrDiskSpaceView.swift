import SwiftUI

struct ArrDiskSpaceView: View {
    @Environment(ArrServiceManager.self) private var serviceManager

    @State private var snapshots: [ArrDiskSpaceSnapshot] = []
    @State private var isLoading = false

    var body: some View {
        Group {
            if !hasConnectedService {
                ContentUnavailableView(
                    "No Arr Services Connected",
                    systemImage: "internaldrive",
                    description: Text("Connect Sonarr or Radarr to inspect storage usage.")
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
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if !sonarrSnapshots.isEmpty {
                            serviceSection(title: "Sonarr", color: .purple, snapshots: sonarrSnapshots)
                        }

                        if !radarrSnapshots.isEmpty {
                            serviceSection(title: "Radarr", color: .orange, snapshots: radarrSnapshots)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .background(backgroundGradient)
        .navigationTitle("Disk Space")
        .task(id: reloadKey) {
            await loadDiskSpace()
        }
        .refreshable {
            await loadDiskSpace()
        }
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

    private func serviceSection(title: String, color: Color, snapshots: [ArrDiskSpaceSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: title == "Sonarr" ? "tv" : "film")
                .font(.headline)
                .foregroundStyle(color)

            ForEach(snapshots) { snapshot in
                DiskSpaceCard(snapshot: snapshot, accentColor: color)
            }
        }
    }
}

private struct DiskSpaceCard: View {
    let snapshot: ArrDiskSpaceSnapshot
    let accentColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.label ?? "Storage")
                        .font(.subheadline.weight(.semibold))
                    Text(snapshot.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 12)

                if let freeSpace = snapshot.freeSpace {
                    Text("\(ByteFormatter.format(bytes: freeSpace)) free")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            if let totalSpace = snapshot.totalSpace, totalSpace > 0, let freeSpace = snapshot.freeSpace {
                let usedSpace = totalSpace - freeSpace
                ProgressView(value: Double(usedSpace), total: Double(totalSpace))
                    .tint(progressTint(totalSpace: totalSpace, freeSpace: freeSpace))

                HStack {
                    Text("Used \(ByteFormatter.format(bytes: usedSpace))")
                    Spacer()
                    Text("Total \(ByteFormatter.format(bytes: totalSpace))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func progressTint(totalSpace: Int64, freeSpace: Int64) -> Color {
        freeSpace > totalSpace / 5 ? accentColor : .orange
    }
}

private protocol ArrDiskSpaceViewProviding: Sendable {
    func getDiskSpace() async throws -> [ArrDiskSpace]
}

extension SonarrAPIClient: ArrDiskSpaceViewProviding {}
extension RadarrAPIClient: ArrDiskSpaceViewProviding {}
