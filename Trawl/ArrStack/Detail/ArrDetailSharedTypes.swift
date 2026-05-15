import SwiftUI

struct ArrDetailBadge: Identifiable {
    let id = UUID()
    let icon: String
    let label: String
    let color: Color
}

struct ArrDetailPendingQueueAction: Identifiable {
    let itemID: Int
    let title: String
    let blocklist: Bool
    var id: String { "\(itemID)-\(blocklist)" }
}

struct ArrBadgeContext {
    let queue: [ArrQueueItem]
    let isInLibrary: Bool
    let hasBazarr: Bool
    var sonarrBazarrEpisodes: [BazarrEpisode] = []
    var radarrBazarrStatus: BazarrSubtitleStatus?
}

protocol BadgeRenderable {
    func detailBadges(context: ArrBadgeContext) -> [ArrDetailBadge]
}

// MARK: - Library-item conformances
// SonarrModels / RadarrModels are members of the widget / share extension targets,
// where `BadgeRenderable` (and `ArrDetailBadge`) aren't compiled. The conformances
// live here so those targets can still compile the model structs.

extension SonarrSeries: BadgeRenderable {
    func detailBadges(context: ArrBadgeContext) -> [ArrDetailBadge] {
        var badges: [ArrDetailBadge] = []
        let isContinuing = status == "continuing"

        badges.append(ArrDetailBadge(
            icon: isContinuing ? "play.circle.fill" : "checkmark.circle.fill",
            label: isContinuing ? "Continuing" : (status?.capitalized ?? "Unknown"),
            color: isContinuing ? .green : .white.opacity(0.6)
        ))

        if let certification, !certification.isEmpty {
            badges.append(ArrDetailBadge(icon: "shield", label: certification, color: .white.opacity(0.8)))
        }

        if context.isInLibrary && monitored == true {
            badges.append(ArrDetailBadge(icon: "bookmark.fill", label: "Monitored", color: .blue))
        }

        let seriesQueue = context.queue.filter { $0.seriesId == id }
        if !seriesQueue.isEmpty {
            let issues = seriesQueue.filter { $0.isImportIssueQueueItem }.count
            let downloading = seriesQueue.filter { $0.isDownloadingQueueItem }.count
            let total = seriesQueue.count

            if issues > 0 {
                badges.append(ArrDetailBadge(
                    icon: "exclamationmark.triangle.fill",
                    label: issues == total
                        ? "\(total) Import Issue\(total == 1 ? "" : "s")"
                        : "\(issues) Import Issue\(issues == 1 ? "" : "s")",
                    color: .orange
                ))
            } else if downloading > 0 {
                badges.append(ArrDetailBadge(
                    icon: "arrow.down.circle.fill",
                    label: downloading == total ? "\(total) Downloading" : "\(downloading) of \(total) Downloading",
                    color: .purple
                ))
            } else {
                let queueStatus = seriesQueue.first?.status?.capitalized ?? "In Queue"
                badges.append(ArrDetailBadge(
                    icon: "clock.arrow.circlepath",
                    label: total == 1 ? queueStatus : "\(total) \(queueStatus)",
                    color: .purple
                ))
            }
        }

        if context.hasBazarr, !context.sonarrBazarrEpisodes.isEmpty {
            let allComplete = context.sonarrBazarrEpisodes.allSatisfy { $0.missingSubtitles.isEmpty }
            badges.append(ArrDetailBadge(
                icon: "captions.bubble.fill",
                label: allComplete ? "Complete" : "None",
                color: allComplete ? .teal : .white.opacity(0.6)
            ))
        }

        return badges
    }
}

extension RadarrMovie: BadgeRenderable {
    func detailBadges(context: ArrBadgeContext) -> [ArrDetailBadge] {
        var badges: [ArrDetailBadge] = []
        let hasFile = self.hasFile == true

        badges.append(ArrDetailBadge(
            icon: hasFile ? "checkmark.circle.fill" : "clock",
            label: displayStatus,
            color: hasFile ? .green : .orange
        ))

        if let cert = certification, !cert.isEmpty {
            badges.append(ArrDetailBadge(icon: "shield", label: cert, color: .white.opacity(0.8)))
        }

        if context.isInLibrary && monitored == true {
            badges.append(ArrDetailBadge(icon: "bookmark.fill", label: "Monitored", color: .blue))
        }

        if let q = context.queue.first(where: { $0.movieId == id }) {
            let isIssue = q.isImportIssueQueueItem
            let isDownloading = q.isDownloadingQueueItem
            badges.append(ArrDetailBadge(
                icon: isIssue ? "exclamationmark.triangle.fill" : (isDownloading ? "arrow.down.circle.fill" : "clock.arrow.circlepath"),
                label: isIssue ? "Import Issue" : (q.status?.capitalized ?? "Downloading"),
                color: isIssue ? .orange : .purple
            ))
        }

        if context.hasBazarr, let status = context.radarrBazarrStatus {
            badges.append(ArrDetailBadge(
                icon: "captions.bubble.fill",
                label: status == .allPresent ? "Complete" : "None",
                color: status == .allPresent ? .teal : .white.opacity(0.6)
            ))
        }

        return badges
    }
}
