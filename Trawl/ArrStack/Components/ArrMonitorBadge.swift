import SwiftUI

struct ArrMonitorBadge: View {
    let isMonitored: Bool
    
    var body: some View {
        if isMonitored {
            Image(systemName: "bookmark.fill")
                .foregroundStyle(.blue)
        }
    }
}
