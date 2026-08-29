import Foundation

// MARK: - Normalized presentation models

nonisolated enum SABnzbdNormalizedStatus: Hashable, Sendable {
    case waiting
    case downloading
    case paused
    case repairing
    case unpacking
    case processing
    case completed
    case failed
    case unknown(String)

    init(rawValue: String) {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "queued", "propagating", "grabbing", "checking", "quickcheck":
            self = .waiting
        case "downloading", "fetching":
            self = .downloading
        case "paused":
            self = .paused
        case "verifying", "repairing":
            self = .repairing
        case "extracting", "unpacking":
            self = .unpacking
        case "moving", "running":
            self = .processing
        case "completed":
            self = .completed
        case "failed":
            self = .failed
        default:
            self = .unknown(rawValue)
        }
    }

    var isActive: Bool {
        switch self {
        case .waiting, .downloading, .paused, .repairing, .unpacking, .processing:
            true
        case .completed, .failed, .unknown:
            false
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed:
            true
        default:
            false
        }
    }
}

nonisolated enum SABnzbdJobSource: String, Hashable, Sendable {
    case queue
    case history
}

/// Stable shape consumed by unified and client-specific download rows.
nonisolated struct SABnzbdJob: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let status: String
    let normalizedStatus: SABnzbdNormalizedStatus
    let progress: Double
    let size: String
    let sizeRemaining: String?
    let totalBytes: Int64?
    let downloadedBytes: Int64?
    let timeRemaining: String?
    let category: String?
    let isPostProcessing: Bool
    let failureMessage: String?
    let addedAt: Date?
    let completedAt: Date?
    let source: SABnzbdJobSource

    init(queueSlot slot: SABnzbdQueueSlot) {
        id = slot.nzoID
        name = slot.filename
        status = slot.status
        normalizedStatus = slot.normalizedStatus
        progress = slot.progress
        size = slot.size
        sizeRemaining = slot.sizeLeft
        if slot.megabytes > 0 {
            let total = Int64((slot.megabytes * 1_048_576).rounded())
            let remainingMegabytes = slot.megabytesLeft > 0
                ? slot.megabytesLeft
                : slot.megabytes * (1 - slot.progress)
            let remaining = Int64((remainingMegabytes * 1_048_576).rounded())
            totalBytes = total
            downloadedBytes = max(0, total - min(remaining, total))
        } else {
            totalBytes = nil
            downloadedBytes = nil
        }
        timeRemaining = slot.timeLeft
        category = slot.category
        isPostProcessing = false
        failureMessage = nil
        addedAt = slot.timeAdded > 0 ? Date(timeIntervalSince1970: TimeInterval(slot.timeAdded)) : nil
        completedAt = nil
        source = .queue
    }

    init(historySlot slot: SABnzbdHistorySlot) {
        id = slot.nzoID
        name = slot.name
        status = slot.status
        normalizedStatus = slot.normalizedStatus
        progress = slot.progress
        size = slot.size
        sizeRemaining = nil
        if slot.bytes > 0 {
            totalBytes = slot.bytes
            downloadedBytes = slot.normalizedStatus == .completed
                ? slot.bytes
                : min(max(0, slot.downloaded), slot.bytes)
        } else {
            totalBytes = nil
            downloadedBytes = nil
        }
        timeRemaining = nil
        category = slot.category
        isPostProcessing = slot.normalizedStatus.isActive
        failureMessage = slot.failMessage.nilIfEmpty
        addedAt = slot.timeAdded > 0 ? Date(timeIntervalSince1970: TimeInterval(slot.timeAdded)) : nil
        completedAt = slot.completed > 0 ? Date(timeIntervalSince1970: TimeInterval(slot.completed)) : nil
        source = .history
    }

    /// Matches torrent rows by presenting transferred bytes before total bytes.
    @MainActor
    var downloadedSizeSummary: String {
        guard let totalBytes, let downloadedBytes else { return size }
        return "\(ByteFormatter.format(bytes: downloadedBytes)) / \(ByteFormatter.format(bytes: totalBytes))"
    }

}

// MARK: - Queue

nonisolated struct SABnzbdQueue: Decodable, Sendable {
    let status: String
    let paused: Bool
    let pausedAll: Bool
    let speed: String
    let kilobytesPerSecond: Double
    let size: String
    let sizeLeft: String
    let megabytes: Double
    let megabytesLeft: Double
    let timeLeft: String
    let noOfSlots: Int
    let noOfSlotsTotal: Int
    let start: Int
    let limit: Int
    let version: String?
    /// Speed cap as a percentage of line speed; `0` means unlimited.
    let speedLimit: Int
    /// Speed cap as an absolute rate in KB/s; `0` means none is set. SABnzbd
    /// reports this separately from `speedLimit` when the limit was set with
    /// a K/M suffix rather than a bare percentage.
    let speedLimitAbsolute: Double
    let slots: [SABnzbdQueueSlot]

    var jobs: [SABnzbdJob] { slots.map(SABnzbdJob.init(queueSlot:)) }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = container.lossyString(forKey: .status) ?? ""
        paused = container.lossyBool(forKey: .paused) ?? false
        pausedAll = container.lossyBool(forKey: .pausedAll) ?? paused
        speed = container.lossyString(forKey: .speed) ?? "0 "
        kilobytesPerSecond = container.lossyDouble(forKey: .kilobytesPerSecond) ?? 0
        size = container.lossyString(forKey: .size) ?? "0 B"
        sizeLeft = container.lossyString(forKey: .sizeLeft) ?? "0 B"
        megabytes = container.lossyDouble(forKey: .megabytes) ?? 0
        megabytesLeft = container.lossyDouble(forKey: .megabytesLeft) ?? 0
        timeLeft = container.lossyString(forKey: .timeLeft) ?? "0:00:00"
        noOfSlots = container.lossyInt(forKey: .noOfSlots) ?? 0
        noOfSlotsTotal = container.lossyInt(forKey: .noOfSlotsTotal) ?? noOfSlots
        start = container.lossyInt(forKey: .start) ?? 0
        limit = container.lossyInt(forKey: .limit) ?? 0
        version = container.lossyString(forKey: .version)
        speedLimit = container.lossyInt(forKey: .speedLimit) ?? 0
        speedLimitAbsolute = container.lossyDouble(forKey: .speedLimitAbsolute) ?? 0
        slots = try container.decodeIfPresent([SABnzbdQueueSlot].self, forKey: .slots) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case status, paused, speed, size, slots, start, limit, version
        case pausedAll = "paused_all"
        case kilobytesPerSecond = "kbpersec"
        case sizeLeft = "sizeleft"
        case megabytes = "mb"
        case megabytesLeft = "mbleft"
        case timeLeft = "timeleft"
        case noOfSlots = "noofslots"
        case noOfSlotsTotal = "noofslots_total"
        case speedLimit = "speedlimit"
        case speedLimitAbsolute = "speedlimit_abs"
    }
}

nonisolated struct SABnzbdQueueSlot: Decodable, Identifiable, Hashable, Sendable {
    let nzoID: String
    let filename: String
    let status: String
    let index: Int
    let priority: String
    let category: String?
    let script: String?
    let timeAdded: Int
    let timeLeft: String
    let percentageValue: Double
    let megabytes: Double
    let megabytesLeft: Double
    let megabytesMissing: Double
    let size: String
    let sizeLeft: String
    let labels: [String]
    let directUnpack: String?
    let unpackOptions: String?

    var id: String { nzoID }
    var normalizedStatus: SABnzbdNormalizedStatus { .init(rawValue: status) }
    var progress: Double { min(max(percentageValue / 100, 0), 1) }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nzoID = container.lossyString(forKey: .nzoID) ?? ""
        filename = container.lossyString(forKey: .filename) ?? "Unknown download"
        status = container.lossyString(forKey: .status) ?? "Unknown"
        index = container.lossyInt(forKey: .index) ?? 0
        priority = container.lossyString(forKey: .priority) ?? "Normal"
        category = container.lossyString(forKey: .category)
        script = container.lossyString(forKey: .script)
        timeAdded = container.lossyInt(forKey: .timeAdded) ?? 0
        timeLeft = container.lossyString(forKey: .timeLeft) ?? "0:00:00"
        percentageValue = container.lossyDouble(forKey: .percentageValue) ?? 0
        megabytes = container.lossyDouble(forKey: .megabytes) ?? 0
        megabytesLeft = container.lossyDouble(forKey: .megabytesLeft) ?? 0
        megabytesMissing = container.lossyDouble(forKey: .megabytesMissing) ?? 0
        size = container.lossyString(forKey: .size) ?? "0 B"
        sizeLeft = container.lossyString(forKey: .sizeLeft) ?? "0 B"
        labels = try container.decodeIfPresent([String].self, forKey: .labels) ?? []
        directUnpack = container.lossyString(forKey: .directUnpack)
        unpackOptions = container.lossyString(forKey: .unpackOptions)
    }

    private enum CodingKeys: String, CodingKey {
        case filename, status, index, priority, script, labels, size
        case nzoID = "nzo_id"
        case category = "cat"
        case timeAdded = "time_added"
        case timeLeft = "timeleft"
        case percentageValue = "percentage"
        case megabytes = "mb"
        case megabytesLeft = "mbleft"
        case megabytesMissing = "mbmissing"
        case sizeLeft = "sizeleft"
        case directUnpack = "direct_unpack"
        case unpackOptions = "unpackopts"
    }
}

// MARK: - History and active post-processing

nonisolated struct SABnzbdHistory: Decodable, Sendable {
    let noOfSlots: Int
    let postProcessingSlots: Int
    let daySize: String
    let weekSize: String
    let monthSize: String
    let totalSize: String
    let lastHistoryUpdate: Int
    let version: String?
    let slots: [SABnzbdHistorySlot]

    var jobs: [SABnzbdJob] { slots.map(SABnzbdJob.init(historySlot:)) }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        noOfSlots = container.lossyInt(forKey: .noOfSlots) ?? 0
        postProcessingSlots = container.lossyInt(forKey: .postProcessingSlots) ?? 0
        daySize = container.lossyString(forKey: .daySize) ?? "0 B"
        weekSize = container.lossyString(forKey: .weekSize) ?? "0 B"
        monthSize = container.lossyString(forKey: .monthSize) ?? "0 B"
        totalSize = container.lossyString(forKey: .totalSize) ?? "0 B"
        lastHistoryUpdate = container.lossyInt(forKey: .lastHistoryUpdate) ?? 0
        version = container.lossyString(forKey: .version)
        slots = try container.decodeIfPresent([SABnzbdHistorySlot].self, forKey: .slots) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case version, slots
        case noOfSlots = "noofslots"
        case postProcessingSlots = "ppslots"
        case daySize = "day_size"
        case weekSize = "week_size"
        case monthSize = "month_size"
        case totalSize = "total_size"
        case lastHistoryUpdate = "last_history_update"
    }
}

nonisolated struct SABnzbdHistorySlot: Decodable, Identifiable, Hashable, Sendable {
    let nzoID: String
    let name: String
    let nzbName: String?
    let status: String
    let category: String?
    let size: String
    let bytes: Int64
    let downloaded: Int64
    let timeAdded: Int
    let completed: Int
    let downloadTime: Int
    let postProcessingTime: Int
    let failMessage: String
    let actionLine: String?
    let scriptLine: String?
    let storage: String?
    let path: String?
    let loaded: Bool
    let retryable: Bool
    let archived: Bool
    let postProcessing: String?
    let stageLog: [SABnzbdStageLog]

    var id: String { nzoID }
    var normalizedStatus: SABnzbdNormalizedStatus { .init(rawValue: status) }
    var progress: Double {
        if normalizedStatus.isTerminal { return 1 }
        guard bytes > 0 else { return 0 }
        return min(max(Double(downloaded) / Double(bytes), 0), 1)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nzoID = container.lossyString(forKey: .nzoID) ?? ""
        name = container.lossyString(forKey: .name) ?? "Unknown download"
        nzbName = container.lossyString(forKey: .nzbName)
        status = container.lossyString(forKey: .status) ?? "Unknown"
        category = container.lossyString(forKey: .category)
        size = container.lossyString(forKey: .size) ?? "0 B"
        bytes = container.lossyInt64(forKey: .bytes) ?? 0
        downloaded = container.lossyInt64(forKey: .downloaded) ?? 0
        timeAdded = container.lossyInt(forKey: .timeAdded) ?? 0
        completed = container.lossyInt(forKey: .completed) ?? 0
        downloadTime = container.lossyInt(forKey: .downloadTime) ?? 0
        postProcessingTime = container.lossyInt(forKey: .postProcessingTime) ?? 0
        failMessage = container.lossyString(forKey: .failMessage) ?? ""
        actionLine = container.lossyString(forKey: .actionLine)
        scriptLine = container.lossyString(forKey: .scriptLine)
        storage = container.lossyString(forKey: .storage)
        path = container.lossyString(forKey: .path)
        loaded = container.lossyBool(forKey: .loaded) ?? false
        retryable = container.lossyBool(forKey: .retryable) ?? false
        archived = container.lossyBool(forKey: .archived) ?? false
        postProcessing = container.lossyString(forKey: .postProcessing)
        stageLog = try container.decodeIfPresent([SABnzbdStageLog].self, forKey: .stageLog) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case name, status, category, size, bytes, downloaded, completed, storage, path, loaded, retry
        case nzoID = "nzo_id"
        case nzbName = "nzb_name"
        case timeAdded = "time_added"
        case downloadTime = "download_time"
        case postProcessingTime = "postproc_time"
        case failMessage = "fail_message"
        case actionLine = "action_line"
        case scriptLine = "script_line"
        case archived = "archive"
        case postProcessing = "pp"
        case stageLog = "stage_log"
        case retryable
    }
}

nonisolated struct SABnzbdStageLog: Decodable, Hashable, Sendable {
    let name: String
    let actions: [String]
}

// MARK: - Add options and API envelopes

nonisolated struct SABnzbdAddOptions: Hashable, Sendable {
    var name: String?
    var password: String?
    var category: String?
    /// Two sentinels rather than one, both confirmed on a live server: "Default"
    /// inherits the global script setting, "None" runs nothing. Neither is a real
    /// script, and `getScripts()` filters both out of the installed list.
    var script: String?
    var priority: Int?
    var postProcessing: Int?

    init(
        name: String? = nil,
        password: String? = nil,
        category: String? = nil,
        script: String? = nil,
        priority: Int? = nil,
        postProcessing: Int? = nil
    ) {
        self.name = name
        self.password = password
        self.category = category
        self.script = script
        self.priority = priority
        self.postProcessing = postProcessing
    }
}

nonisolated enum SABnzbdAuthentication: String, Decodable, Sendable {
    case apiKey = "apikey"
    case nzbKey = "nzbkey"
    case badKey = "badkey"
}

nonisolated struct SABnzbdQueueEnvelope: Decodable, Sendable {
    let queue: SABnzbdQueue
}

nonisolated struct SABnzbdHistoryEnvelope: Decodable, Sendable {
    let history: SABnzbdHistory?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(Bool.self, forKey: .history), value == false {
            history = nil
        } else {
            history = try container.decode(SABnzbdHistory.self, forKey: .history)
        }
    }

    private enum CodingKeys: String, CodingKey { case history }
}

nonisolated struct SABnzbdVersionEnvelope: Decodable, Sendable {
    let version: String
}

nonisolated struct SABnzbdAuthenticationEnvelope: Decodable, Sendable {
    let authentication: SABnzbdAuthentication

    private enum CodingKeys: String, CodingKey { case authentication = "auth" }
}

/// `mode=get_cats` and `mode=get_scripts` both return a bare list. SABnzbd puts its
/// "use the server default" sentinel first as "*" / "Default"; callers strip it.
nonisolated struct SABnzbdCategoriesEnvelope: Decodable, Sendable {
    let categories: [String]
}

nonisolated struct SABnzbdScriptsEnvelope: Decodable, Sendable {
    let scripts: [String]
}

nonisolated struct SABnzbdCommandResponse: Decodable, Sendable {
    let status: Bool?
    let error: String?
    let nzoIDs: [String]
    let nzoID: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = container.lossyBool(forKey: .status)
        error = container.lossyString(forKey: .error)
        nzoIDs = try container.decodeIfPresent([String].self, forKey: .nzoIDs) ?? []
        nzoID = container.lossyString(forKey: .nzoID)
    }

    private enum CodingKeys: String, CodingKey {
        case status, error
        case nzoIDs = "nzo_ids"
        case nzoID = "nzo_id"
    }
}

nonisolated struct SABnzbdErrorResponse: Decodable, Sendable {
    let status: Bool?
    let error: String?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = container.lossyBool(forKey: .status)
        error = container.lossyString(forKey: .error)
    }

    private enum CodingKeys: String, CodingKey { case status, error }
}

// MARK: - Lossy SABnzbd scalar decoding

private nonisolated extension KeyedDecodingContainer {
    func lossyString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return String(value) }
        return nil
    }

    func lossyDouble(forKey key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return Double(value) }
        if let value = try? decodeIfPresent(String.self, forKey: key) { return Double(value) }
        return nil
    }

    func lossyInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value) ?? Double(value).map(Int.init)
        }
        return nil
    }

    func lossyInt64(forKey key: Key) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int64(value) }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int64(value) ?? Double(value).map(Int64.init)
        }
        return nil
    }

    func lossyBool(forKey key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }
}

private nonisolated extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

#if DEBUG
// MARK: - Preview fixtures

nonisolated extension SABnzbdQueue {
    /// Decoded from a trimmed-down copy of a real SABnzbd `mode=queue` payload so
    /// the previews exercise the same lossy decoding path the app uses.
    static var preview: SABnzbdQueue {
        let json = """
        {
          "status": "Downloading",
          "paused": false,
          "paused_all": false,
          "speed": "8.4 M",
          "kbpersec": 8600.0,
          "size": "12.4 GB",
          "sizeleft": "3.1 GB",
          "mb": 12697.6,
          "mbleft": 3174.4,
          "timeleft": "0:06:12",
          "noofslots": 2,
          "noofslots_total": 2,
          "start": 0,
          "limit": 200,
          "version": "4.3.2",
          "slots": [
            {
              "nzo_id": "SABnzbd_nzo_preview1",
              "filename": "Blade.Runner.2049.2017.2160p.UHD.BluRay.x265-TERMINAL",
              "status": "Downloading",
              "index": 0,
              "priority": "High",
              "cat": "movies",
              "script": "None",
              "time_added": 1755600000,
              "timeleft": "0:06:12",
              "percentage": "75",
              "mb": 12697.6,
              "mbleft": 3174.4,
              "mbmissing": 0.0,
              "size": "12.4 GB",
              "sizeleft": "3.1 GB",
              "labels": [],
              "direct_unpack": "12",
              "unpackopts": "3"
            },
            {
              "nzo_id": "SABnzbd_nzo_preview2",
              "filename": "Severance.S02E07.1080p.WEB.h264-GROUP",
              "status": "Paused",
              "index": 1,
              "priority": "Normal",
              "cat": "tv",
              "script": "None",
              "time_added": 1755603000,
              "timeleft": "0:00:00",
              "percentage": "12",
              "mb": 4096.0,
              "mbleft": 3604.0,
              "mbmissing": 0.0,
              "size": "4.0 GB",
              "sizeleft": "3.5 GB",
              "labels": ["TOO SLOW"],
              "unpackopts": "3"
            }
          ]
        }
        """
        return decodePreview(json)
    }
}

nonisolated extension SABnzbdHistory {
    static var preview: SABnzbdHistory {
        let json = """
        {
          "noofslots": 2,
          "ppslots": 0,
          "day_size": "42.1 GB",
          "week_size": "180.6 GB",
          "month_size": "702.3 GB",
          "total_size": "8.1 TB",
          "last_history_update": 1755610000,
          "version": "4.3.2",
          "slots": [
            {
              "nzo_id": "SABnzbd_nzo_history1",
              "name": "Dune.Part.Two.2024.2160p.WEB-DL-GROUP",
              "nzb_name": "Dune.Part.Two.2024.2160p.WEB-DL-GROUP.nzb",
              "status": "Completed",
              "cat": "movies",
              "size": "18.9 GB",
              "bytes": 20293386240,
              "downloaded": 20293386240,
              "time_added": 1755500000,
              "completed": 1755506400,
              "download_time": 5400,
              "postproc_time": 320,
              "fail_message": "",
              "action_line": "",
              "script_line": "",
              "storage": "/data/complete/movies/Dune Part Two (2024)",
              "path": "/data/complete/movies/Dune Part Two (2024)",
              "loaded": false,
              "retry": false,
              "archive": false,
              "pp": "D",
              "stage_log": [
                { "name": "Download", "actions": ["Downloaded in 1 hour 30 minutes at an average of 3.7 MB/s"] },
                { "name": "Unpack", "actions": ["[Dune.Part.Two] Unpacked 1 files/folders in 4 seconds"] }
              ]
            },
            {
              "nzo_id": "SABnzbd_nzo_history2",
              "name": "The.Bear.S03E04.1080p.WEB.h264-GROUP",
              "status": "Failed",
              "cat": "tv",
              "size": "2.4 GB",
              "bytes": 2576980377,
              "downloaded": 1288490188,
              "time_added": 1755400000,
              "completed": 1755401500,
              "download_time": 900,
              "postproc_time": 0,
              "fail_message": "Unpacking failed, archive is damaged (CRC error)",
              "storage": "",
              "loaded": false,
              "retry": true,
              "archive": false,
              "pp": "D",
              "stage_log": [
                { "name": "Repair", "actions": ["Repair failed, not enough repair blocks (needed 512)"] }
              ]
            }
          ]
        }
        """
        return decodePreview(json)
    }
}

private nonisolated func decodePreview<T: Decodable>(_ json: String) -> T {
    // Force-unwrapped on purpose: these literals ship only in DEBUG previews, and
    // a decode failure there is a fixture bug that should surface immediately.
    // swiftlint:disable:next force_try
    try! JSONDecoder().decode(T.self, from: Data(json.utf8))
}

nonisolated extension SABnzbdJob {
    static var previewDownloading: SABnzbdJob { SABnzbdQueue.preview.jobs[0] }
    static var previewPaused: SABnzbdJob { SABnzbdQueue.preview.jobs[1] }
    static var previewCompleted: SABnzbdJob { SABnzbdHistory.preview.jobs[0] }
    static var previewFailed: SABnzbdJob { SABnzbdHistory.preview.jobs[1] }
}
#endif

// MARK: - News servers

/// One Usenet server as SABnzbd's `get_config&section=servers` reports it.
///
/// SABnzbd is inconsistent about scalar types across versions and across fields:
/// the same flag comes back as `1`, `"1"` or `true` depending on where you ask.
/// Every value is therefore read leniently rather than trusting one shape, and
/// everything is optional so a field this app doesn't know about can't fail the
/// whole decode.
nonisolated struct SABnzbdNewsServer: Codable, Identifiable, Sendable {
    var name: String
    var displayName: String?
    var host: String
    var port: Int
    var username: String?
    var password: String?
    var connections: Int
    var ssl: Bool
    var sslVerify: Int?
    var enabled: Bool
    var optional: Bool
    var retention: Int?
    var timeout: Int?
    var priority: Int?
    var notes: String?

    /// SABnzbd keys a server by its `name`, which is what `set_config` and
    /// `del_config` address it by.
    var id: String { name }

    var title: String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { return trimmed }
        return name.isEmpty ? host : name
    }

    var hostLine: String {
        port > 0 ? "\(host):\(port)" : host
    }

    enum CodingKeys: String, CodingKey {
        case name
        case displayName = "displayname"
        case host, port, username, password, connections, ssl
        case sslVerify = "ssl_verify"
        case enabled = "enable"
        case optional, retention, timeout, priority, notes
    }

    init(
        name: String,
        displayName: String? = nil,
        host: String,
        port: Int = 563,
        username: String? = nil,
        password: String? = nil,
        connections: Int = 8,
        ssl: Bool = true,
        sslVerify: Int? = nil,
        enabled: Bool = true,
        optional: Bool = false,
        retention: Int? = nil,
        timeout: Int? = nil,
        priority: Int? = nil,
        notes: String? = nil
    ) {
        self.name = name
        self.displayName = displayName
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.connections = connections
        self.ssl = ssl
        self.sslVerify = sslVerify
        self.enabled = enabled
        self.optional = optional
        self.retention = retention
        self.timeout = timeout
        self.priority = priority
        self.notes = notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = Self.string(container, .name) ?? ""
        self.displayName = Self.string(container, .displayName)
        self.host = Self.string(container, .host) ?? ""
        self.port = Self.int(container, .port) ?? 563
        self.username = Self.string(container, .username)
        self.password = Self.string(container, .password)
        self.connections = Self.int(container, .connections) ?? 1
        self.ssl = Self.bool(container, .ssl) ?? false
        self.sslVerify = Self.int(container, .sslVerify)
        self.enabled = Self.bool(container, .enabled) ?? true
        self.optional = Self.bool(container, .optional) ?? false
        self.retention = Self.int(container, .retention)
        self.timeout = Self.int(container, .timeout)
        self.priority = Self.int(container, .priority)
        self.notes = Self.string(container, .notes)
    }

    private static func string(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return String(value) }
        return nil
    }

    private static func int(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) { return Int(value) }
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) { return value ? 1 : 0 }
        return nil
    }

    private static func bool(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Bool? {
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            switch value.lowercased() {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            default: return nil
            }
        }
        return nil
    }
}

nonisolated struct SABnzbdServersEnvelope: Decodable, Sendable {
    let config: Config

    nonisolated struct Config: Decodable, Sendable {
        let servers: [SABnzbdNewsServer]?
    }
}

// MARK: - Categories

/// A SABnzbd category as `get_config&section=categories` reports it. The bare
/// `get_cats` list used for pickers gives names only; this carries the settings
/// behind each one.
///
/// Decoded leniently for the same reason `SABnzbdNewsServer` is: SABnzbd's scalar
/// types vary by version and by field.
nonisolated struct SABnzbdCategory: Codable, Identifiable, Sendable {
    var name: String
    var order: Int?
    /// Post-processing level: 0 download, 1 +repair, 2 +unpack, 3 +delete.
    ///
    /// Verified against SABnzbd 5.1.1: this comes back as a *string* ("3"), and is
    /// empty on any category that inherits the global setting. `nil` here means
    /// inherit - writing an explicit level to such a category would silently pin
    /// it to whatever the editor happened to be showing.
    var postProcessing: Int?
    var script: String?
    var directory: String?
    var priority: Int?

    var id: String { name }

    /// SABnzbd's own catch-all category. It can be edited but not deleted, and
    /// renaming it would orphan every job that references it.
    var isDefault: Bool { name == "*" }

    var displayName: String { isDefault ? "Default" : name }

    enum CodingKeys: String, CodingKey {
        case name, order, script, priority
        case postProcessing = "pp"
        case directory = "dir"
    }

    init(
        name: String,
        order: Int? = nil,
        postProcessing: Int? = nil,
        script: String? = nil,
        directory: String? = nil,
        priority: Int? = nil
    ) {
        self.name = name
        self.order = order
        self.postProcessing = postProcessing
        self.script = script
        self.directory = directory
        self.priority = priority
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = Self.string(container, .name) ?? ""
        self.order = Self.int(container, .order)
        self.postProcessing = Self.int(container, .postProcessing)
        self.script = Self.string(container, .script)
        self.directory = Self.string(container, .directory)
        self.priority = Self.int(container, .priority)
    }

    private static func string(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> String? {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return String(value) }
        return nil
    }

    private static func int(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) { return Int(value) }
        return nil
    }
}

extension SABnzbdCategory {
    static let inheritScript = "Default"
    static let noScript = "None"

    /// A script value that names an actual script, rather than one of SABnzbd's
    /// two sentinels.
    var realScriptName: String? {
        guard let script, !script.isEmpty else { return nil }
        guard script != Self.inheritScript, script != Self.noScript else { return nil }
        return script
    }
}

nonisolated struct SABnzbdCategoriesConfigEnvelope: Decodable, Sendable {
    let config: Config

    nonisolated struct Config: Decodable, Sendable {
        let categories: [SABnzbdCategory]?
    }
}

/// `mode=config&name=test_server` replies `{"value":{"result":Bool,"message":String}}`.
nonisolated struct SABnzbdServerTestEnvelope: Decodable, Sendable {
    let value: Value

    nonisolated struct Value: Decodable, Sendable {
        let result: Bool?
        let message: String?
    }
}

/// The post-processing levels SABnzbd offers per category.
nonisolated enum SABnzbdPostProcessing: Int, CaseIterable, Identifiable, Sendable {
    case download = 0
    case repair = 1
    case unpack = 2
    case delete = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .download: "Download"
        case .repair: "+ Repair"
        case .unpack: "+ Unpack"
        case .delete: "+ Delete"
        }
    }
}

/// Category priorities, matching SABnzbd's own values.
nonisolated enum SABnzbdCategoryPriority: Int, CaseIterable, Identifiable, Sendable {
    case `default` = -100
    case paused = -2
    case low = -1
    case normal = 0
    case high = 1
    case force = 2

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .default: "Default"
        case .paused: "Paused"
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        case .force: "Force"
        }
    }
}
