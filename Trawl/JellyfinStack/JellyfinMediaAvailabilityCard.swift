import SwiftUI

struct JellyfinMediaAvailabilityCard: View {
    enum Media: Sendable {
        case movie(title: String, year: Int?, tmdbId: Int?, imdbId: String?)
        case series(title: String, year: Int?, tvdbId: Int?, tmdbId: Int?, imdbId: String?)

        var title: String {
            switch self {
            case .movie(let title, _, _, _), .series(let title, _, _, _, _): title
            }
        }

        var year: Int? {
            switch self {
            case .movie(_, let year, _, _), .series(_, let year, _, _, _): year
            }
        }

        var itemTypes: [String] {
            switch self {
            case .movie: ["Movie"]
            case .series: ["Series"]
            }
        }

        var taskKey: String {
            switch self {
            case .movie(let title, let year, let tmdbId, let imdbId):
                "movie-\(title)-\(year?.description ?? "nil")-\(tmdbId?.description ?? "nil")-\(imdbId ?? "nil")"
            case .series(let title, let year, let tvdbId, let tmdbId, let imdbId):
                "series-\(title)-\(year?.description ?? "nil")-\(tvdbId?.description ?? "nil")-\(tmdbId?.description ?? "nil")-\(imdbId ?? "nil")"
            }
        }

        var providerIdPairs: [(provider: String, id: String)] {
            switch self {
            case .movie(_, _, let tmdbId, let imdbId):
                var pairs: [(String, String)] = []
                if let id = tmdbId { pairs.append(("Tmdb", String(id))) }
                if let id = imdbId, !id.isEmpty { pairs.append(("Imdb", id)) }
                return pairs
            case .series(_, _, let tvdbId, let tmdbId, let imdbId):
                var pairs: [(String, String)] = []
                if let id = tvdbId { pairs.append(("Tvdb", String(id))) }
                if let id = tmdbId { pairs.append(("Tmdb", String(id))) }
                if let id = imdbId, !id.isEmpty { pairs.append(("Imdb", id)) }
                return pairs
            }
        }
    }

    let media: Media
    @Environment(JellyfinServiceManager.self) private var serviceManager
    @State private var refreshedItemIDs: Set<String> = []
    @State private var isExpanded = false

    private var key: JellyfinAvailabilityResolver.Key? {
        serviceManager.activeProfileID.map { .init(profileID: $0, mediaTaskKey: media.taskKey) }
    }

    private var resolverState: JellyfinAvailabilityResolver.State {
        key.map { serviceManager.availability.state(for: $0) } ?? .idle
    }

    var body: some View {
        if serviceManager.isConnected || serviceManager.connectionError != nil || serviceManager.isConnecting {
            cardContent
                .task(id: "\(media.taskKey)-\(serviceManager.activeProfileID?.uuidString ?? "none")") {
                    isExpanded = false
                    refreshedItemIDs = []
                    guard let key, let client = serviceManager.activeClient else { return }
                    serviceManager.availability.ensureLoaded(key, media: media, client: client)
                }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if isExpanded {
                if serviceManager.isConnecting {
                    loadingRow("Connecting to Jellyfin...")
                } else {
                    switch resolverState {
                    case .idle:
                        EmptyView()
                    case .loading:
                        loadingRow("Checking Jellyfin...")
                    case .resolved(let items):
                        if items.isEmpty {
                            unavailableRow
                        } else {
                            matchedRows(items)
                        }
                    case .failed(let message):
                        errorRow(message)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    private var header: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: availabilityIconName)
                    .foregroundStyle(availabilityTint)
                    .frame(width: 24, alignment: .leading)
                Text("Jellyfin")
                    .font(.headline)
                Spacer()
                if case .loading = resolverState {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Text(availabilityStatusText)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(availabilityTint.opacity(0.16), in: Capsule())
                        .foregroundStyle(availabilityTint)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }

    private var availabilityStatusText: String {
        switch resolverState {
        case .idle, .loading: return "Check"
        case .resolved(let items): return items.isEmpty ? "Not Present" : "Present"
        case .failed: return "Error"
        }
    }

    private var availabilityIconName: String {
        switch resolverState {
        case .idle, .loading: return "play.tv"
        case .resolved(let items): return items.isEmpty ? "play.slash.fill" : "play.tv.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var availabilityTint: Color {
        switch resolverState {
        case .idle, .loading: return .secondary
        case .resolved(let items): return items.isEmpty ? .orange : .green
        case .failed: return .orange
        }
    }

    private func matchedRows(_ items: [JellyfinLibraryItem]) -> some View {
        VStack(spacing: 10) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.name ?? media.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(2)

                            HStack(spacing: 6) {
                                if let productionYear = item.productionYear {
                                    Text(String(productionYear))
                                }
                                if let runtimeMinutes = item.runtimeMinutes {
                                    Text("\(runtimeMinutes)m")
                                }
                                if let fileSize = item.fileSize, fileSize > 0 {
                                    Text(ByteFormatter.format(bytes: fileSize))
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        Button {
                            Task { await refresh(item) }
                        } label: {
                            if refreshedItemIDs.contains(item.id) {
                                Image(systemName: "checkmark.circle.fill")
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(refreshedItemIDs.contains(item.id))
                        .accessibilityLabel("Refresh Jellyfin item")
                    }

                    if let path = item.path ?? item.mediaSources?.compactMap(\.path).first, !path.isEmpty {
                        Text(path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                .padding(12)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var unavailableRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(media.title) is not in Jellyfin.")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("No matching Jellyfin library item was found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private func loadingRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func errorRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Retry") {
                guard let key, let client = serviceManager.activeClient else { return }
                serviceManager.availability.invalidate(key)
                serviceManager.availability.ensureLoaded(key, media: media, client: client)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func refresh(_ item: JellyfinLibraryItem) async {
        guard let client = serviceManager.activeClient, let key else { return }
        do {
            try await client.refreshItem(id: item.id)
            refreshedItemIDs.insert(item.id)
            serviceManager.availability.invalidate(key)
            serviceManager.availability.ensureLoaded(key, media: media, client: client)
            InAppNotificationCenter.shared.showSuccess(
                title: "Jellyfin Refresh Started",
                message: "\(item.name ?? media.title) was sent for metadata refresh.",
                source: .inApp
            )
        } catch {
            InAppNotificationCenter.shared.showError(
                title: "Jellyfin Refresh Failed",
                message: error.localizedDescription,
                source: .inApp
            )
        }
    }
}
