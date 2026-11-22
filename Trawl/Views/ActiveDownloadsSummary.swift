import Foundation

/// What the bar above the iPhone tab bar says about downloads.
///
/// Downloads lost its tab on iPhone and moved into that bar, the way a music app
/// keeps what is playing in a strip above its tabs. So the bar needs one line for
/// "what is downloading right now": the furthest-along item by name, how far it has
/// got, and how many more are behind it.
///
/// Seeding is not downloading. A torrent that has finished is still busy - it is in
/// the old tab badge's count - but the bar is answering "is my thing here yet?", and
/// a seeding torrent has already answered that.
struct ActiveDownloadsSummary: Equatable, Sendable {
    /// The item the bar names.
    let leadName: String
    /// 0...1.
    let leadProgress: Double
    /// Everything downloading, the lead included.
    let count: Int
    /// Combined download speed, in bytes per second, where the client reports one.
    let bytesPerSecond: Int64

    var othersCount: Int { max(0, count - 1) }

    /// `nil` when nothing is downloading, which leaves the bar to notifications.
    static func make(torrents: [Torrent], sabJobs: [SABnzbdJob]) -> ActiveDownloadsSummary? {
        struct Item { let name: String; let progress: Double; let speed: Int64 }

        let torrentItems = torrents
            .filter { $0.progress < 1 && $0.isRunningInTabBadge }
            .map { Item(name: $0.name, progress: $0.progress, speed: $0.dlspeed) }
        let sabItems = sabJobs
            .filter { !$0.isPostProcessing && $0.progress < 1 }
            .map { Item(name: $0.name, progress: $0.progress, speed: 0) }
        let items = torrentItems + sabItems
        guard !items.isEmpty else { return nil }

        // Nearest to done first: that is the one the user is waiting on, and it is
        // the one about to change into a notification.
        let lead = items.max { lhs, rhs in
            lhs.progress == rhs.progress ? lhs.name > rhs.name : lhs.progress < rhs.progress
        }!
        return ActiveDownloadsSummary(
            leadName: lead.name,
            leadProgress: min(max(lead.progress, 0), 1),
            count: items.count,
            bytesPerSecond: items.reduce(0) { $0 + $1.speed }
        )
    }

    /// "42%", or "42% · 2 more".
    var detail: String {
        let percent = "\(Int((leadProgress * 100).rounded(.down)))%"
        return othersCount == 0 ? percent : "\(percent) · \(othersCount) more"
    }
}
