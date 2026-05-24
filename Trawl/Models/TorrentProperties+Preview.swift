#if DEBUG
import Foundation

extension TorrentProperties {
    static let preview: TorrentProperties = {
        let json: [String: Any] = [
            "save_path": "/downloads",
            "creation_date": 1_700_000_000,
            "piece_size": 4_194_304,
            "comment": "",
            "total_wasted": 0,
            "total_uploaded": 100_000_000,
            "total_downloaded": 500_000_000,
            "up_limit": 0,
            "dl_limit": 0,
            "time_elapsed": 3600,
            "seeding_time": 1800,
            "nb_connections": 12,
            "share_ratio": 0.2,
            "addition_date": 1_700_000_000,
            "completion_date": 1_700_003_600,
            "created_by": "qBittorrent",
            "last_seen": 1_700_007_200,
            "peers": 3,
            "seeds": 12,
            "pieces_have": 256,
            "pieces_num": 512
        ]
        let data = try! JSONSerialization.data(withJSONObject: json, options: [])
        return try! JSONDecoder().decode(TorrentProperties.self, from: data)
    }()
}
#endif
