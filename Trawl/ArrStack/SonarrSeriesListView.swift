import SwiftUI
import SwiftData

struct SonarrSeriesListView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @Environment(SyncService.self) private var syncService
    @Environment(JellyfinServiceManager.self) private var jellyfinManager

    @State private var viewModel: SonarrViewModel?
    @State private var viewModelInstanceID: UUID?

    var body: some View {
        Group {
            if let vm = viewModel {
                ArrMediaListView(
                    viewModel: vm,
                    serviceType: .sonarr,
                    nounSingular: "Series",
                    nounPlural: "Series",
                    emptyIcon: "tv",
                    row: { series, _ in
                        SonarrSeriesRow(
                            series: series,
                            hasIssue: vm.queue.contains {
                                $0.seriesId == series.id && $0.isImportIssueQueueItem
                            },
                            bazarrStatus: serviceManager.bazarrSubtitleStatus(forSonarrSeriesId: series.id)
                        )
                    },
                    detailDestination: { seriesId in
                        AnyView(SonarrSeriesDetailView(seriesId: seriesId, viewModel: vm))
                    }
                )
            } else {
                Color.clear
            }
        }
        .task(id: viewModelLoadKey) {
            let activeID = serviceManager.activeSonarrInstanceID
            guard serviceManager.sonarrConnected else {
                viewModel = nil
                viewModelInstanceID = nil
                return
            }
            if viewModel == nil || viewModelInstanceID != activeID {
                viewModel = SonarrViewModel(serviceManager: serviceManager, jellyfinManager: jellyfinManager)
                viewModelInstanceID = activeID
            }
        }
    }

    private var viewModelLoadKey: String {
        "\(serviceManager.activeSonarrInstanceID?.uuidString ?? "none"):\(serviceManager.sonarrConnected)"
    }
}

// MARK: - Series Row

struct SonarrSeriesRow: View {
    let series: SonarrSeries
    let hasIssue: Bool
    var bazarrStatus: BazarrSubtitleStatus? = nil

    var body: some View {
        HStack(spacing: 12) {
            ArrArtworkView(url: series.posterURL) {
                Rectangle().fill(.quaternary)
                    .overlay(Image(systemName: "tv").foregroundStyle(.secondary))
            }
            .frame(width: 50, height: 75)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Text(series.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    ForEach(Array(metadataItems.enumerated()), id: \.offset) { index, item in
                        if index > 0 {
                            Text("•")
                                .foregroundStyle(.secondary)
                        }
                        Text(item.title)
                            .foregroundStyle(item.color)
                    }
                    .font(.caption2)
                }

                HStack(spacing: 6) {
                    if let stats = series.statistics {
                        let fileCount = stats.episodeFileCount ?? 0
                        let totalCount = stats.episodeCount ?? 0
                        ProgressView(value: totalCount > 0 ? Double(fileCount) / Double(totalCount) : 0)
                            .tint(fileCount == totalCount ? .green : .blue)
                            .frame(width: 40)
                        Text("\(fileCount)/\(totalCount) eps")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if let bazarrStatus {
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Image(systemName: "captions.bubble.fill")
                            .font(.caption2)
                            .foregroundStyle(bazarrStatus == .allPresent ? .teal : .secondary)
                    }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                if hasIssue {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                ArrMonitorBadge(isMonitored: series.monitored == true)
                    .font(.caption)
            }
        }
        .padding(.vertical, 4)
    }

    private var metadataItems: [SeriesRowMetadataItem] {
        var items: [SeriesRowMetadataItem] = []
        if let year = series.year {
            items.append(.init(title: String(year), color: .secondary))
        }
        if let network = series.network, !network.isEmpty {
            items.append(.init(title: network, color: .secondary))
        }
        if let status = series.status, !status.isEmpty {
            items.append(.init(
                title: status.capitalized,
                color: status == "continuing" ? .green : .secondary
            ))
        }
        return items
    }
}

private struct SeriesRowMetadataItem {
    let title: String
    let color: Color
}
