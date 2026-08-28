import SwiftUI

/// What the library actually has, said in one pill.
///
/// With a single server this is just "Available" or the item's own status. With
/// an HD/4K pair it also says *which* copies exist — "Available HD & 4K",
/// "Available HD", "Available 4K" — because that gap is the entire reason to run
/// two servers, and it should be readable from the row without opening anything.
///
/// This deliberately replaced a sentence ("Downloaded on HD only"). A status is a
/// pill: it is scanned, not read, and it has to sit in a row next to a title
/// without competing with it.
struct ArrAvailabilityPill: View {
    /// The tiers that actually hold a file, in HD-then-4K order.
    let availableTiers: [ArrQualityTier]
    /// Whether to name the tiers. False when only one server is configured, where
    /// "Available HD" would imply a 4K library that does not exist.
    let showsTiers: Bool
    /// What to say when nothing is downloaded yet — the item's own status, like
    /// "Missing" or "Announced".
    let unavailableStatus: String

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .lineLimit(1)
    }

    var label: String {
        Self.label(
            availableTiers: availableTiers,
            showsTiers: showsTiers,
            unavailableStatus: unavailableStatus
        )
    }

    /// Pure, so the wording is testable without rendering.
    static func label(
        availableTiers: [ArrQualityTier],
        showsTiers: Bool,
        unavailableStatus: String
    ) -> String {
        guard !availableTiers.isEmpty else { return unavailableStatus }
        guard showsTiers else { return "Available" }
        let ordered = ArrQualityTier.allCases.filter { availableTiers.contains($0) }
        return "Available \(ordered.map(\.label).joined(separator: " & "))"
    }

    private var tint: Color {
        availableTiers.isEmpty ? .secondary : .green
    }
}

extension ArrLibraryEntry {
    /// The tiers holding a file, given the servers this entry lives on.
    ///
    /// `refs` and `copies` are matched by instance rather than by position: a
    /// filtered or partially-loaded library can hand back fewer refs than copies,
    /// and zipping them would then label a copy with the wrong server.
    func availableTiers(from refs: [ArrInstanceRef], hasFile: (Item) -> Bool) -> [ArrQualityTier] {
        let tiersByInstance = Dictionary(refs.map { ($0.id, $0.tier) }, uniquingKeysWith: { first, _ in first })
        return copies.compactMap { copy in
            guard hasFile(copy), let instanceID = copy.instanceID else { return nil }
            return tiersByInstance[instanceID]
        }
    }
}

#if DEBUG
#Preview("Availability") {
    VStack(alignment: .leading, spacing: 12) {
        ArrAvailabilityPill(availableTiers: [.hd, .uhd], showsTiers: true, unavailableStatus: "Missing")
        ArrAvailabilityPill(availableTiers: [.hd], showsTiers: true, unavailableStatus: "Missing")
        ArrAvailabilityPill(availableTiers: [.uhd], showsTiers: true, unavailableStatus: "Missing")
        ArrAvailabilityPill(availableTiers: [.hd], showsTiers: false, unavailableStatus: "Missing")
        ArrAvailabilityPill(availableTiers: [], showsTiers: true, unavailableStatus: "Missing")
    }
    .padding()
}
#endif
