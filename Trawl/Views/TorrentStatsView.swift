import SwiftUI
import Charts

struct TorrentStatsView: View {
    @Environment(SyncService.self) private var syncService
    #if DEBUG
    private var previewServerState: ServerState?
    private var previewSpeedHistory: [SyncService.SpeedSample]?
    #endif

    init() {}

    var body: some View {
        let state = resolvedServerState
        let history = resolvedSpeedHistory
        List {
            if !history.isEmpty {
                Section {
                    SpeedGraphView(history: history)
                        .frame(height: 140)
                        .padding(4)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                } header: {
                    HStack {
                        Label("Download", systemImage: "circle.fill")
                            .foregroundStyle(.blue)
                            .font(.caption)
                        Spacer()
                        Label("Upload", systemImage: "circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }
            }

            Section("Session") {
                statRow("Download Speed",
                        value: ByteFormatter.formatSpeed(bytesPerSecond: state?.dlInfoSpeed ?? 0),
                        icon: "arrow.down.circle", color: .blue)
                statRow("Upload Speed",
                        value: ByteFormatter.formatSpeed(bytesPerSecond: state?.upInfoSpeed ?? 0),
                        icon: "arrow.up.circle", color: .green)
                statRow("Downloaded",
                        value: ByteFormatter.format(bytes: state?.dlInfoData ?? 0),
                        icon: "arrow.down", color: .blue)
                statRow("Uploaded",
                        value: ByteFormatter.format(bytes: state?.upInfoData ?? 0),
                        icon: "arrow.up", color: .green)
            }

            if let dl = state?.alltimeDl, let ul = state?.alltimeUl {
                Section("All Time") {
                    statRow("Total Downloaded",
                            value: ByteFormatter.format(bytes: dl),
                            icon: "arrow.down.to.line", color: .blue)
                    statRow("Total Uploaded",
                            value: ByteFormatter.format(bytes: ul),
                            icon: "arrow.up.to.line", color: .green)
                    if dl > 0 {
                        let ratio = Double(ul) / Double(dl)
                        statRow("Ratio",
                                value: String(format: "%.3f", ratio),
                                icon: "arrow.left.arrow.right",
                                color: ratio >= 1 ? .green : .orange)
                    }
                }
            }

            Section("Network") {
                if let peers = state?.totalPeerConnections {
                    statRow("Connected Peers", value: "\(peers)", icon: "person.2.fill", color: .purple)
                }
                if let nodes = state?.dhtNodes {
                    statRow("DHT Nodes", value: "\(nodes)", icon: "network", color: .indigo)
                }
                if let status = state?.connectionStatus {
                    statRow("Status", value: status.capitalized, icon: "wifi", color: .mint)
                }
                if let dlLimit = state?.dlRateLimit, dlLimit > 0 {
                    statRow("Download Limit",
                            value: ByteFormatter.formatSpeed(bytesPerSecond: dlLimit),
                            icon: "arrow.down.circle.dotted", color: .secondary)
                }
                if let upLimit = state?.upRateLimit, upLimit > 0 {
                    statRow("Upload Limit",
                            value: ByteFormatter.formatSpeed(bytesPerSecond: upLimit),
                            icon: "arrow.up.circle.dotted", color: .secondary)
                }
                if let free = state?.freeSpaceOnDisk {
                    statRow("Free Disk Space",
                            value: ByteFormatter.format(bytes: free),
                            icon: "internaldrive", color: .teal)
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
        .scrollContentBackground(.hidden)
        .moreDestinationBackground(.transferStats)
        .navigationTitle("Transfer Stats")
        .navigationSubtitle("qBittorrent")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func statRow(_ label: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 22)
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var resolvedServerState: ServerState? {
        #if DEBUG
        if let previewServerState { return previewServerState }
        #endif
        return syncService.serverState
    }

    private var resolvedSpeedHistory: [SyncService.SpeedSample] {
        #if DEBUG
        if let previewSpeedHistory { return previewSpeedHistory }
        #endif
        return syncService.speedHistory
    }
}

// MARK: - Speed Graph

struct SpeedGraphView: View {
    let history: [SyncService.SpeedSample]

    var body: some View {
        Chart {
            ForEach(Array(history.enumerated()), id: \.offset) { index, sample in
                AreaMark(
                    x: .value("Time", index),
                    yStart: .value("Base", 0.0),
                    yEnd: .value("Download", Double(sample.dlSpeed))
                )
                .foregroundStyle(.blue.opacity(0.25))
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Time", index),
                    y: .value("Download", Double(sample.dlSpeed)),
                    series: .value("Series", "DL")
                )
                .foregroundStyle(.blue)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)

                AreaMark(
                    x: .value("Time", index),
                    yStart: .value("Base", 0.0),
                    yEnd: .value("Upload", Double(sample.upSpeed))
                )
                .foregroundStyle(.green.opacity(0.25))
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Time", index),
                    y: .value("Upload", Double(sample.upSpeed)),
                    series: .value("Series", "UL")
                )
                .foregroundStyle(.green)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(ByteFormatter.formatSpeed(bytesPerSecond: Int64(v)))
                            .font(.caption2)
                    }
                }
                AxisGridLine()
            }
        }
        .chartYScale(domain: 0.0 ... Double(max(maxSpeed, 1024)))
    }

    private var maxSpeed: Int64 {
        history.map { max($0.dlSpeed, $0.upSpeed) }.max() ?? 0
    }
}

#if DEBUG
extension TorrentStatsView {
    init(
        previewServerState: ServerState?,
        previewSpeedHistory: [SyncService.SpeedSample] = []
    ) {
        self.previewServerState = previewServerState
        self.previewSpeedHistory = previewSpeedHistory
    }
}

extension ServerState {
    static let preview = ServerState(
        dlInfoSpeed: 4_500_000,
        dlInfoData: 8_750_000_000,
        upInfoSpeed: 820_000,
        upInfoData: 1_900_000_000,
        dlRateLimit: 0,
        upRateLimit: 5_000_000,
        dhtNodes: 412,
        connectionStatus: "connected",
        alltimeDl: 4_820_000_000_000,
        alltimeUl: 3_650_000_000_000,
        totalPeerConnections: 128,
        freeSpaceOnDisk: 890_000_000_000,
        globalRatio: "0.76"
    )
}

extension Array where Element == SyncService.SpeedSample {
    static var previewSpeedHistory: [SyncService.SpeedSample] {
        let now = Date()
        var samples: [SyncService.SpeedSample] = []
        samples.reserveCapacity(36)

        for index in 0..<36 {
            let timestamp = now.addingTimeInterval(Double(index - 36) * 2)
            let downloadSpeed = Int64(1_000_000 + (index % 9) * 450_000)
            let uploadSpeed = Int64(250_000 + (index % 6) * 120_000)
            samples.append(
                SyncService.SpeedSample(
                    timestamp: timestamp,
                    dlSpeed: downloadSpeed,
                    upSpeed: uploadSpeed
                )
            )
        }

        return samples
    }
}

#Preview("Loaded") {
    PreviewHost(profiles: .qBittorrentOnly) {
        NavigationStack {
            TorrentStatsView(
                previewServerState: .preview,
                previewSpeedHistory: .previewSpeedHistory
            )
        }
    }
}

#Preview("Empty") {
    PreviewHost(profiles: .qBittorrentOnly) {
        NavigationStack {
            TorrentStatsView(previewServerState: nil)
        }
    }
}

#Preview("Loading") {
    // TorrentStatsView has no built-in loading indicator; show the empty skeleton
    // the view produces while waiting for the first SyncService poll to arrive.
    PreviewHost(profiles: .qBittorrentOnly) {
        NavigationStack {
            TorrentStatsView(previewServerState: nil, previewSpeedHistory: [])
        }
    }
}

#Preview("Error") {
    // Simulate a connection-error banner wrapping the stats shell.
    PreviewHost(profiles: .qBittorrentOnly) {
        NavigationStack {
            ZStack(alignment: .top) {
                TorrentStatsView(previewServerState: nil, previewSpeedHistory: [])
                VStack {
                    Label(
                        "Unable to connect to qBittorrent — check your server settings.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding()
                    Spacer()
                }
            }
        }
    }
}
#endif
