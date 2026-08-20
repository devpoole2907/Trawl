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
    let timeRemaining: String?
    let category: String?
    let isPostProcessing: Bool
    let failureMessage: String?
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
        timeRemaining = slot.timeLeft
        category = slot.category
        isPostProcessing = false
        failureMessage = nil
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
        timeRemaining = nil
        category = slot.category
        isPostProcessing = slot.normalizedStatus.isActive
        failureMessage = slot.failMessage.nilIfEmpty
        completedAt = slot.completed > 0 ? Date(timeIntervalSince1970: TimeInterval(slot.completed)) : nil
        source = .history
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
