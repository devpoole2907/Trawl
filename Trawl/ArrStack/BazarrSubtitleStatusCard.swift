import SwiftUI

struct BazarrSubtitleStatusCard: View {
    enum Media {
        case movie(radarrId: Int, title: String)
        case series(seriesId: Int, title: String)
    }

    let media: Media
    @Environment(ArrServiceManager.self) private var serviceManager
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var movie: BazarrMovie?
    @State private var series: BazarrSeries?
    @State private var isSearching = false
    @State private var showInteractiveSearch = false

    private var accent: Color { .teal }

    var body: some View {
        if serviceManager.hasBazarrInstance {
            cardContent
                .task(id: taskID) {
                    await load()
                }
                .sheet(isPresented: $showInteractiveSearch) {
                    if let movie {
                BazarrInteractiveSearchSheet(
                    radarrId: movie.radarrId,
                    missingLanguages: movie.missingSubtitles,
                    viewModel: BazarrViewModel(serviceManager: serviceManager),
                    onDownloaded: {
                        await serviceManager.refreshActiveBazarrSubtitleCache()
                        await load(force: true)
                    }
                )
            }
        }
        }
    }

    private var taskID: String {
        let connectionKey = "\(serviceManager.hasAnyConnectedBazarrInstance)-\(serviceManager.activeBazarrProfileID?.uuidString ?? "none")"
        switch media {
        case .movie(let id, _): return "movie-\(id)-\(connectionKey)"
        case .series(let id, _): return "series-\(id)-\(connectionKey)"
        }
    }

    private var title: String {
        switch media {
        case .movie: "Subtitles"
        case .series: "Subtitles"
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "captions.bubble.fill")
                    .foregroundStyle(accent)
                Text(title)
                    .font(.headline)
                Spacer()
                statusBadge
            }

            if !serviceManager.hasAnyConnectedBazarrInstance {
                disconnectedContent
            } else if isLoading && movie == nil && series == nil {
                loadingContent
            } else if let errorMessage {
                errorContent(errorMessage)
            } else {
                loadedContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        } else if missingCount > 0 {
            Text("\(missingCount) missing")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
        } else if hasLoadedMedia {
            Text("Complete")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
        }
    }

    private var disconnectedContent: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Bazarr is configured but not connected.")
                    .font(.subheadline.weight(.semibold))
                if let error = serviceManager.bazarrConnectionError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button("Retry") {
                Task { await serviceManager.retry(.bazarr) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(accent)
        }
    }

    private var loadingContent: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Checking Bazarr...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func errorContent(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Retry") {
                Task { await load(force: true) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(accent)
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        if hasLoadedMedia {
            VStack(alignment: .leading, spacing: 12) {
                Text(summaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if missingCount > 0 {
                    HStack(spacing: 12) {
                        Button {
                            Task { await searchMissing() }
                        } label: {
                            searchButtonLabel(
                                title: "Automatic",
                                subtitle: "Search for missing",
                                systemImage: "magnifyingglass",
                                isLoading: isSearching
                            )
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .disabled(isSearching)

                        if case .movie = media {
                            Button {
                                showInteractiveSearch = true
                            } label: {
                                searchButtonLabel(
                                    title: "Interactive",
                                    subtitle: "Pick a release",
                                    systemImage: "person.fill",
                                    trailingSystemImage: "arrow.up.forward.square"
                                )
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        } else {
            Text("Bazarr has not imported this item yet. Make sure Bazarr is connected to the matching Sonarr/Radarr library.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func searchButtonLabel(
        title: String,
        subtitle: String,
        systemImage: String,
        isLoading: Bool = false,
        trailingSystemImage: String = "arrow.right"
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(accent)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: trailingSystemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 18)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .padding(12)
        .contentShape(Rectangle())
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16))
    }

    private var hasLoadedMedia: Bool {
        movie != nil || series != nil
    }

    private var missingCount: Int {
        if let movie {
            return movie.missingSubtitles.count
        }
        if let series {
            return series.episodeMissingCount
        }
        return 0
    }

    private var summaryText: String {
        if let movie {
            if movie.missingSubtitles.isEmpty {
                return movie.subtitles.isEmpty ? "Bazarr is tracking this movie. No missing subtitles are reported." : "\(movie.subtitles.count) subtitle file\(movie.subtitles.count == 1 ? "" : "s") available."
            }
            return "\(movie.missingSubtitles.count) language\(movie.missingSubtitles.count == 1 ? "" : "s") missing for this movie."
        }
        if let series {
            if series.episodeMissingCount == 0 {
                return "Bazarr reports all tracked episode subtitles are present."
            }
            return "\(series.episodeMissingCount) missing subtitle\(series.episodeMissingCount == 1 ? "" : "s") across \(series.episodeFileCount) episode file\(series.episodeFileCount == 1 ? "" : "s")."
        }
        return ""
    }

    private func load(force: Bool = false) async {
        if isLoading { return }
        guard serviceManager.hasAnyConnectedBazarrInstance else { return }
        guard force || !hasLoadedMedia else { return }
        guard let client = serviceManager.activeBazarrEntry?.client else { return }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            switch media {
            case .movie(let radarrId, _):
                let page = try await client.getMovies(ids: [radarrId])
                movie = page.data.first
            case .series(let seriesId, _):
                let page = try await client.getSeries(ids: [seriesId])
                series = page.data.first
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func searchMissing() async {
        guard let client = serviceManager.activeBazarrEntry?.client else { return }
        isSearching = true
        defer { isSearching = false }

        do {
            switch media {
            case .movie(let radarrId, let title):
                try await client.runMovieAction(radarrId: radarrId, action: .searchMissing)
                InAppNotificationCenter.shared.showSuccess(title: "Subtitle Search Started", message: "\(title) was sent to Bazarr.")
            case .series(let seriesId, let title):
                try await client.runSeriesAction(seriesId: seriesId, action: .searchMissing)
                InAppNotificationCenter.shared.showSuccess(title: "Subtitle Search Started", message: "\(title) was sent to Bazarr.")
            }
            movie = nil
            series = nil
            await serviceManager.refreshActiveBazarrSubtitleCache()
            await load(force: true)
        } catch {
            InAppNotificationCenter.shared.showError(title: "Subtitle Search Failed", message: error.localizedDescription)
        }
    }
}
