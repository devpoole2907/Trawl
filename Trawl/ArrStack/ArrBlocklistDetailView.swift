import SwiftUI

struct ArrBlocklistDetailView: View {
    let entry: ArrBlocklistView.BlocklistEntry
    let onUnblock: () async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var showUnblockConfirmation = false
    @State private var isUnblocking = false

    private var item: ArrBlocklistItem { entry.item }

    var body: some View {
        Form {
            Section {
                TrawlEntityHeader(
                    title: item.sourceTitle ?? "Unknown Release",
                    subtitle: "Blocked Release",
                    systemImage: "hand.raised.slash.fill",
                    tint: .red,
                    badges: headerBadges
                )
            }
            .listRowBackground(Color.clear)

            if let message = nonempty(item.message) {
                Section {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } header: {
                    Label("Reason", systemImage: "exclamationmark.triangle")
                }
            }

            Section {
                LabeledContent("Service", value: entry.source.displayName)
                LabeledContent("Server", value: entry.instance.displayName)
                if let indexer = nonempty(item.indexer) {
                    LabeledContent("Indexer", value: indexer)
                }
                if let quality = nonempty(item.quality?.quality?.name) {
                    LabeledContent("Quality", value: quality)
                }
                if let blockedAt {
                    LabeledContent("Blocked", value: blockedAt.formatted(date: .abbreviated, time: .shortened))
                }
            } header: {
                Label("Release", systemImage: "shippingbox")
            }

            if item.seriesId != nil || item.movieId != nil || !(item.episodeIds ?? []).isEmpty {
                Section {
                    if let seriesId = item.seriesId {
                        LabeledContent("Series ID", value: String(seriesId))
                    }
                    if let movieId = item.movieId {
                        LabeledContent("Movie ID", value: String(movieId))
                    }
                    if let episodeIds = item.episodeIds, !episodeIds.isEmpty {
                        LabeledContent("Episode IDs", value: episodeIds.map(String.init).joined(separator: ", "))
                    }
                } header: {
                    Label("Related Item", systemImage: entry.source == .sonarr ? "tv" : "film")
                }
            }
        }
        .serviceSettingsFormStyle()
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
        .paneAwareNavigationTitle("Blocked Release", subtitle: entry.instance.displayName)
        .toolbar {
            ToolbarItem(placement: platformTopBarTrailingPlacement) {
                Button("Unblock", systemImage: "arrow.uturn.backward") {
                    showUnblockConfirmation = true
                }
                .disabled(isUnblocking)
            }
        }
        .confirmationDialog(
            "Unblock Release?",
            isPresented: $showUnblockConfirmation,
            titleVisibility: .visible
        ) {
            Button("Unblock", role: .destructive) {
                Task { await unblock() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This release will be allowed to download again.")
        }
    }

    private var headerBadges: [ArrDetailBadge] {
        var badges = [
            ArrDetailBadge(icon: entry.source.systemImage, label: entry.source.displayName, color: entry.source.serviceIdentity.brandColor)
        ]
        if let quality = nonempty(item.quality?.quality?.name) {
            badges.append(ArrDetailBadge(icon: "sparkles", label: quality, color: .secondary))
        }
        return badges
    }

    private var blockedAt: Date? {
        guard let raw = nonempty(item.date) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func unblock() async {
        isUnblocking = true
        let didUnblock = await onUnblock()
        isUnblocking = false
        if didUnblock { dismiss() }
    }
}

#if DEBUG
#Preview("Blocked Series Release") {
    PreviewHost(profiles: .arrOnly, arr: .preview(.allConfigured)) {
        NavigationStack {
            ArrBlocklistDetailView(
                entry: .init(
                    instanced: ArrInstanced(ArrBlocklistItem.preview, on: .preview(.sonarr)),
                    source: .sonarr
                ),
                onUnblock: { true }
            )
        }
    }
}
#endif
