import SwiftUI

struct TorrentRowView: View {
    let torrent: Torrent
    var isProcessing: Bool = false

    var body: some View {
        TorrentSummaryView(torrent: torrent, isProcessing: isProcessing)
        .padding(.vertical, 6)
    }
}
