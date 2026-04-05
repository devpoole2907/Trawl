import Foundation

struct TorrentFile: Codable, Identifiable, Sendable {
    var id: Int { index }

    let index: Int
    let name: String
    let size: Int64
    let progress: Double
    let priority: FilePriority
    let isSeed: Bool?
    let availability: Double?

    enum CodingKeys: String, CodingKey {
        case name, size, progress, priority
        case isSeed = "is_seed"
        case availability
    }

    /// The API does not return an index field — it must be assigned from
    /// the array position during decoding.
    nonisolated init(index: Int, name: String, size: Int64, progress: Double, priority: FilePriority, isSeed: Bool?, availability: Double?) {
        self.index = index
        self.name = name
        self.size = size
        self.progress = progress
        self.priority = priority
        self.isSeed = isSeed
        self.availability = availability
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Index will be assigned post-decode; use -1 as sentinel
        self.index = -1
        self.name = try container.decode(String.self, forKey: .name)
        self.size = try container.decode(Int64.self, forKey: .size)
        self.progress = try container.decode(Double.self, forKey: .progress)
        self.priority = try container.decode(FilePriority.self, forKey: .priority)
        self.isSeed = try container.decodeIfPresent(Bool.self, forKey: .isSeed)
        self.availability = try container.decodeIfPresent(Double.self, forKey: .availability)
    }

    /// Returns a copy with the index set to the given value
    nonisolated func withIndex(_ index: Int) -> TorrentFile {
        TorrentFile(index: index, name: name, size: size, progress: progress, priority: priority, isSeed: isSeed, availability: availability)
    }
}

enum FilePriority: Int, Codable, CaseIterable, Identifiable, Sendable {
    case doNotDownload = 0
    case normal = 1
    case high = 6
    case maximum = 7

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .doNotDownload: "Do Not Download"
        case .normal: "Normal"
        case .high: "High"
        case .maximum: "Maximum"
        }
    }

    var systemImage: String {
        switch self {
        case .doNotDownload: "xmark.circle"
        case .normal: "arrow.down.circle"
        case .high: "arrow.up.circle"
        case .maximum: "flame.fill"
        }
    }
}
