import SwiftUI
import Charts

struct TorrentStatsView: View {
    @Environment(SyncService.self) private var syncService

    var body: some View {
        let state = syncService.serverState
        List {
            if !syncService.speedHistory.isEmpty {
                Section {
                    SpeedGraphView(history: syncService.speedHistory)
                        .frame(height: 140)
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
