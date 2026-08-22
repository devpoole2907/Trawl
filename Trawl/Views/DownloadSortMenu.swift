import SwiftUI

nonisolated protocol DownloadSortOption: CaseIterable, Equatable, Identifiable, Sendable {
    var title: String { get }
}

extension DownloadSortOption where Self: RawRepresentable, RawValue == String {
    nonisolated var title: String { rawValue }
}

/// Shared toolbar interaction used by the qBittorrent, SABnzbd, and unified
/// download lists. Each screen supplies the sort choices appropriate to its data.
struct DownloadSortMenu<Option: DownloadSortOption>: View {
    @Binding var selection: Option
    let defaultSelection: Option

    var body: some View {
        Menu {
            ForEach(Array(Option.allCases)) { option in
                Button {
                    withAnimation { selection = option }
                } label: {
                    if selection == option {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }
        } label: {
            Label(
                "Sort",
                systemImage: selection == defaultSelection
                    ? "arrow.up.arrow.down"
                    : "arrow.up.arrow.down.circle.fill"
            )
        }
    }
}

nonisolated enum DownloadSortCriterion: String, DownloadSortOption {
    case name = "Name"
    case date = "Date"
    case size = "Size"
    case progress = "Progress"
    case eta = "ETA"
    case status = "Status"

    var id: String { rawValue }

    func areInIncreasingOrder(_ lhs: DownloadSortValues, _ rhs: DownloadSortValues) -> Bool {
        let primary: Bool?
        switch self {
        case .name:
            primary = Self.textComparison(lhs.name, rhs.name)
        case .date:
            primary = Self.optionalComparison(lhs.date, rhs.date, prefersGreater: true)
        case .size:
            primary = Self.optionalComparison(lhs.size, rhs.size, prefersGreater: true)
        case .progress:
            primary = Self.optionalComparison(lhs.progress, rhs.progress, prefersGreater: true)
        case .eta:
            primary = Self.optionalComparison(lhs.eta, rhs.eta, prefersGreater: false)
        case .status:
            primary = Self.textComparison(lhs.status, rhs.status)
        }

        if let primary { return primary }
        if let nameComparison = Self.textComparison(lhs.name, rhs.name) { return nameComparison }
        return lhs.identifier < rhs.identifier
    }

    private static func textComparison(_ lhs: String, _ rhs: String) -> Bool? {
        switch lhs.localizedCaseInsensitiveCompare(rhs) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: nil
        }
    }

    /// Missing metrics always sort last, independent of the metric's direction.
    private static func optionalComparison<Value: Comparable>(
        _ lhs: Value?,
        _ rhs: Value?,
        prefersGreater: Bool
    ) -> Bool? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?) where lhs != rhs:
            prefersGreater ? lhs > rhs : lhs < rhs
        case (_?, nil):
            true
        case (nil, _?):
            false
        default:
            nil
        }
    }
}

nonisolated struct DownloadSortValues: Sendable {
    let identifier: String
    let name: String
    let date: Date?
    let size: Int64?
    let progress: Double?
    let eta: TimeInterval?
    let status: String

    static func etaSeconds(from text: String?) -> TimeInterval? {
        guard let text else { return nil }
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        let seconds = parts[0] * 3_600 + parts[1] * 60 + parts[2]
        return seconds > 0 ? seconds : nil
    }
}
