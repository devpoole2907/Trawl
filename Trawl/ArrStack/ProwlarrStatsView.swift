import SwiftUI

struct ProwlarrStatsView: View {
    @Environment(ArrServiceManager.self) private var serviceManager
    @State private var viewModel: ProwlarrViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                content(vm: vm)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Indexer Stats")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .task {
            if viewModel == nil {
                viewModel = ProwlarrViewModel(serviceManager: serviceManager)
            }
            await viewModel?.loadStats()
        }
    }

    @ViewBuilder
    private func content(vm: ProwlarrViewModel) -> some View {
        if vm.isLoadingStats && vm.indexerStats == nil {
            ProgressView("Loading stats…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = vm.statsError {
            ContentUnavailableView {
                Label("Failed to Load Stats", systemImage: "chart.bar.xaxis")
            } description: {
                Text(error)
            } actions: {
                Button("Retry", systemImage: "arrow.clockwise") {
                    Task { await vm.loadStats() }
                }
            }
        } else if let stats = vm.indexerStats {
            statsList(stats: stats)
                .refreshable { await vm.loadStats() }
        } else {
            ContentUnavailableView(
                "No Stats Yet",
                systemImage: "chart.bar",
                description: Text("Run some searches or RSS syncs to generate indexer statistics.")
            )
        }
    }

    @ViewBuilder
    private func statsList(stats: ProwlarrIndexerStats) -> some View {
        let entries = (stats.indexers ?? []).sorted { ($0.numberOfQueries ?? 0) > ($1.numberOfQueries ?? 0) }

        List {
            // Summary totals
            let totalQueries = entries.compactMap(\.numberOfQueries).reduce(0, +)
            let totalGrabs = entries.compactMap(\.numberOfGrabs).reduce(0, +)
            let totalFailed = entries.compactMap(\.numberOfFailedQueries).reduce(0, +)

            Section("Overview") {
                summaryRow(icon: "magnifyingglass", color: .yellow, label: "Total Queries", value: "\(totalQueries)")
                summaryRow(icon: "arrow.down.circle.fill", color: .green, label: "Total Grabs", value: "\(totalGrabs)")
                summaryRow(icon: "xmark.circle.fill", color: .red, label: "Failed Queries", value: "\(totalFailed)")
                if totalQueries > 0 {
                    let rate = Double(totalQueries - totalFailed) / Double(totalQueries) * 100
                    summaryRow(icon: "chart.line.uptrend.xyaxis", color: .blue, label: "Overall Success", value: String(format: "%.1f%%", rate))
                }
            }

            if !entries.isEmpty {
                Section("Per Indexer") {
                    ForEach(entries) { entry in
                        IndexerStatRow(entry: entry)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(backgroundGradient)
    }

    private func summaryRow(icon: String, color: Color, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(color)
                .frame(width: 24)
            Text(label)
                .foregroundStyle(.primary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
        }
    }

    private var backgroundGradient: some View {
        ZStack {
            LinearGradient(
                colors: [Color.yellow.opacity(0.12), Color.clear],
                startPoint: .top,
                endPoint: .center
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Per-Indexer Stat Row

private struct IndexerStatRow: View {
    let entry: ProwlarrIndexerStatEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.indexerName ?? "Unknown Indexer")
                .font(.subheadline.weight(.medium))

            HStack(spacing: 16) {
                statCell(value: entry.numberOfQueries, label: "Queries", color: .primary)
                statCell(value: entry.numberOfGrabs, label: "Grabs", color: .green)
                statCell(value: entry.numberOfFailedQueries, label: "Failed", color: .red)

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    if let avg = entry.avgResponseTimeFormatted {
                        Text(avg)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    if let rate = entry.successRate {
                        Text(String(format: "%.0f%%", rate * 100))
                            .font(.caption2)
                            .foregroundStyle(rate > 0.9 ? .green : rate > 0.7 ? .orange : .red)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func statCell(value: Int?, label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value.map(String.init) ?? "—")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
