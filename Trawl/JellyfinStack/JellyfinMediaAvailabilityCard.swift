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
    }

    let media: Media
    @Environment(JellyfinServiceManager.self) private var serviceManager
    @State private var matchedItems: [JellyfinLibraryItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var refreshedItemIDs: Set<String> = []
    @State private var isExpanded = false
    @State private var hasLoadedAvailability = false

    var body: some View {
        if serviceManager.isConnected || serviceManager.connectionError != nil || serviceManager.isConnecting {
            cardContent
                .task(id: "\(media.taskKey)-\(serviceManager.activeProfileID?.uuidString ?? "none")") {
                    isExpanded = false
                    matchedItems = []
                    errorMessage = nil
                    refreshedItemIDs = []
                    hasLoadedAvailability = false
                }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if isExpanded {
                if serviceManager.isConnecting {
                    loadingRow("Connecting to Jellyfin...")
                } else if let errorMessage {
                    errorRow(errorMessage)
                } else if isLoading && matchedItems.isEmpty {
                    loadingRow("Checking Jellyfin...")
                } else if matchedItems.isEmpty {
                    unavailableRow
                } else {
                    matchedRows
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    private var header: some View {
        Button {
            let shouldLoad = !isExpanded
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                isExpanded.toggle()
            }
            if shouldLoad {
                Task { await loadAvailability() }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: availabilityIconName)
                    .foregroundStyle(availabilityTint)
                    .frame(width: 24, alignment: .leading)
                Text("Jellyfin")
                    .font(.headline)
                Spacer()
                if isLoading {
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
        if errorMessage != nil { return "Error" }
        guard hasLoadedAvailability else { return "Check" }
        return matchedItems.isEmpty ? "Not Present" : "Present"
    }

    private var availabilityIconName: String {
        if errorMessage != nil { return "exclamationmark.triangle.fill" }
        guard hasLoadedAvailability else { return "play.tv" }
        return matchedItems.isEmpty ? "play.slash.fill" : "play.tv.fill"
    }

    private var availabilityTint: Color {
        if errorMessage != nil { return .orange }
        guard hasLoadedAvailability else { return .secondary }
        return matchedItems.isEmpty ? .orange : .green
    }

    private var matchedRows: some View {
        VStack(spacing: 10) {
            ForEach(matchedItems) { item in
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
                Task { await loadAvailability(force: true) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func loadAvailability(force: Bool = false) async {
        guard !isLoading else { return }
        guard force || !hasLoadedAvailability else { return }
        guard let client = serviceManager.activeClient else {
            errorMessage = serviceManager.connectionError
            hasLoadedAvailability = true
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let items = try await client.getAllLibraryItems(includeItemTypes: media.itemTypes)
            matchedItems = items.filter(matches).sorted { lhs, rhs in
                (lhs.name ?? "") < (rhs.name ?? "")
            }
            hasLoadedAvailability = true
        } catch {
            errorMessage = error.localizedDescription
            hasLoadedAvailability = true
        }
    }

    private func refresh(_ item: JellyfinLibraryItem) async {
        guard let client = serviceManager.activeClient else { return }
        do {
            try await client.refreshItem(id: item.id)
            refreshedItemIDs.insert(item.id)
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

    private func matches(_ item: JellyfinLibraryItem) -> Bool {
        switch media {
        case .movie(let title, let year, let tmdbId, let imdbId):
            if matchesNumericProvider(item, keys: ["Tmdb", "TMDb"], id: tmdbId) { return true }
            if matchesStringProvider(item, keys: ["Imdb", "IMDb", "IMDB"], id: imdbId) { return true }
            return titleYearFallbackMatches(item, title: title, year: year)
        case .series(let title, let year, let tvdbId, let tmdbId, let imdbId):
            if matchesNumericProvider(item, keys: ["Tvdb", "TVDB"], id: tvdbId) { return true }
            if matchesNumericProvider(item, keys: ["Tmdb", "TMDb"], id: tmdbId) { return true }
            if matchesStringProvider(item, keys: ["Imdb", "IMDb", "IMDB"], id: imdbId) { return true }
            return titleYearFallbackMatches(item, title: title, year: year)
        }
    }

    private func matchesNumericProvider(_ item: JellyfinLibraryItem, keys: [String], id: Int?) -> Bool {
        guard let id, let value = item.providerID(for: keys) else { return false }
        return value.trimmingCharacters(in: .whitespacesAndNewlines) == String(id)
    }

    private func matchesStringProvider(_ item: JellyfinLibraryItem, keys: [String], id: String?) -> Bool {
        guard let id, !id.isEmpty, let value = item.providerID(for: keys) else { return false }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(id) == .orderedSame
    }

    private func titleYearFallbackMatches(_ item: JellyfinLibraryItem, title: String, year: Int?) -> Bool {
        guard normalizedTitle(item.name) == normalizedTitle(title) else { return false }
        guard let year else { return true }
        return item.productionYear == nil || item.productionYear == year
    }

    private func normalizedTitle(_ value: String?) -> String {
        (value ?? "")
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined()
    }
}
