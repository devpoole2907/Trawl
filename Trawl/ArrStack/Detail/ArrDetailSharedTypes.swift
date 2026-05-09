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
