#if DEBUG
import Foundation

extension TorrentFile {
    static let preview = TorrentFile(
        index: 0, name: "sample.mkv", size: 1_200_000_000,
        progress: 0.5, priority: .normal, isSeed: nil, availability: nil
    )
    static let previewList: [TorrentFile] = [
        preview,
        .init(index: 1, name: "extras/bonus.mkv", size: 200_000_000, progress: 0.0, priority: .doNotDownload, isSeed: nil, availability: nil),
        .init(index: 2, name: "subtitles/en.srt", size: 50_000, progress: 1.0, priority: .normal, isSeed: nil, availability: nil),
    ]
}
#endif
