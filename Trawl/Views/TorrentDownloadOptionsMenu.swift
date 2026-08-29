import SwiftUI

/// The "Download Options" submenu - sequential download, first/last piece priority,
/// and per-torrent speed limits. Shared between the torrent detail toolbar and the
/// torrent list row context menu so both expose the same controls.
///
/// Owns a `TorrentDetailViewModel` for the given torrent so it can drive the
/// per-torrent actions and lazily load the current speed limits when the menu opens.
struct TorrentDownloadOptionsMenu: View {
    let torrent: Torrent
    let downloadLimitFallback: Int64?
    let uploadLimitFallback: Int64?

    @State private var viewModel: TorrentDetailViewModel
    @State private var selectedDownloadLimit: Int64 = 0
    @State private var selectedUploadLimit: Int64 = 0

    init(
        torrent: Torrent,
        torrentService: TorrentService,
        syncService: SyncService,
        notificationCenter: InAppNotificationCenter,
        downloadLimitFallback: Int64?,
        uploadLimitFallback: Int64?
    ) {
        self.torrent = torrent
        self.downloadLimitFallback = downloadLimitFallback
        self.uploadLimitFallback = uploadLimitFallback
        _viewModel = State(initialValue: TorrentDetailViewModel(
            torrentHash: torrent.hash,
            torrentService: torrentService,
            syncService: syncService,
            notificationCenter: notificationCenter
        ))
    }

    var body: some View {
        Menu {
            Toggle(
                "Sequential Download",
                isOn: Binding(
                    get: { viewModel.isSequentialDownloadEnabled },
                    set: { enabled in
                        Task { await viewModel.setSequentialDownload(enabled) }
                    }
                )
            )
            .disabled(viewModel.isUpdatingSequentialDownload)

            Toggle(
                "First and Last Pieces First",
                isOn: Binding(
                    get: { viewModel.isFirstLastPiecePriorityEnabled },
                    set: { enabled in
                        Task { await viewModel.setFirstLastPiecePriority(enabled) }
                    }
                )
            )
            .disabled(viewModel.isUpdatingFirstLastPiecePriority)

            Menu {
                Menu {
                    Picker(
                        "Download Limit",
                        selection: Binding(
                            get: { selectedDownloadLimit },
                            set: { newVal in
                                selectedDownloadLimit = newVal
                                Task { await viewModel.setTorrentDownloadLimit(newVal) }
                            }
                        )
                    ) {
                        ForEach(limitOptions(including: max(0, viewModel.properties?.dlLimit ?? 0)), id: \.self) { limit in
                            Text(torrentLimitLabel(limit, globalFallback: downloadLimitFallback)).tag(limit)
                        }
                    }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }

                Menu {
                    Picker(
                        "Upload Limit",
                        selection: Binding(
                            get: { selectedUploadLimit },
                            set: { newVal in
                                selectedUploadLimit = newVal
                                Task { await viewModel.setTorrentUploadLimit(newVal) }
                            }
                        )
                    ) {
                        ForEach(limitOptions(including: max(0, viewModel.properties?.upLimit ?? 0)), id: \.self) { limit in
                            Text(torrentLimitLabel(limit, globalFallback: uploadLimitFallback)).tag(limit)
                        }
                    }
                } label: {
                    Label("Upload", systemImage: "arrow.up.circle")
                }
            } label: {
                Label("Speed Limits", systemImage: "speedometer")
            }
        } label: {
            Label("Download Options", systemImage: "arrow.down")
        }
        .task {
            await viewModel.loadProperties()
            if let properties = viewModel.properties {
                selectedDownloadLimit = max(0, properties.dlLimit)
                selectedUploadLimit = max(0, properties.upLimit)
            }
        }
        .onChange(of: viewModel.properties) { _, newProperties in
            if let properties = newProperties {
                selectedDownloadLimit = max(0, properties.dlLimit)
                selectedUploadLimit = max(0, properties.upLimit)
            }
        }
    }

    private func limitOptions(including currentLimit: Int64) -> [Int64] {
        let megabyte = Int64(1_048_576)
        var options: [Int64] = [
            0,
            megabyte,
            5 * megabyte,
            10 * megabyte,
            25 * megabyte,
            50 * megabyte,
            100 * megabyte
        ]
        if currentLimit > 0, !options.contains(currentLimit) {
            options.append(currentLimit)
            options.sort()
        }
        return options
    }

    private func torrentLimitLabel(_ limit: Int64, globalFallback: Int64?) -> String {
        if limit == 0 {
            let fallback = globalFallback ?? 0
            return fallback == 0 ? "Use Global (Unlimited)" : "Use Global (\(ByteFormatter.formatSpeed(bytesPerSecond: fallback)))"
        }
        return ByteFormatter.formatSpeed(bytesPerSecond: limit)
    }
}
