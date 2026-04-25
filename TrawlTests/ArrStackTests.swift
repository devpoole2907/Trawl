import Testing
import Foundation
@testable import Trawl

@Suite("ArrError Tests")
struct ArrErrorTests {
    @Test("Error Descriptions", arguments: [
        (ArrError.invalidAPIKey, "Invalid API key. Check your *arr service settings."),
        (.invalidURL, "Invalid service URL."),
        (.invalidResponse, "Invalid response from server."),
        (.noServiceConfigured, "No service configured.")
    ])
    func staticErrorDescriptions(error: ArrError, expected: String) {
        #expect(error.errorDescription == expected)
    }

    @Test("Connection Failed Description")
    func connectionFailedDescription() {
        let error = ArrError.connectionFailed
        let desc = try? #require(error.errorDescription)
        #expect(desc?.contains("Could not connect") == true)
    }

    @Test("Network Error Description")
    func networkErrorDescription() {
        struct FakeError: LocalizedError {
            var errorDescription: String? { "timeout" }
        }
        let error = ArrError.networkError(FakeError())
        #expect(error.errorDescription == "Network error: timeout")
    }

    @Test("Decoding Error Description")
    func decodingErrorDescription() {
        struct FakeError: LocalizedError {
            var errorDescription: String? { "bad JSON" }
        }
        let error = ArrError.decodingError(FakeError())
        #expect(error.errorDescription == "Failed to parse response: bad JSON")
    }

    @Test("Server Error Description", arguments: [
        (500, "Internal Server Error" as String?, "Server error (500): Internal Server Error"),
        (503, nil as String?, "Server error (503): Unknown")
    ])
    func serverErrorDescription(statusCode: Int, message: String?, expected: String) {
        let error = ArrError.serverError(statusCode: statusCode, message: message)
        #expect(error.errorDescription == expected)
    }
}

@Suite("ArrServiceType Tests")
struct ArrServiceTypeTests {
    @Test("Properties", arguments: [
        (ArrServiceType.sonarr, "Sonarr", 8989, "tv", "sonarr"),
        (.radarr, "Radarr", 7878, "film", "radarr"),
        (.prowlarr, "Prowlarr", 9696, "magnifyingglass.circle", "prowlarr")
    ])
    func properties(type: ArrServiceType, name: String, port: Int, image: String, raw: String) {
        #expect(type.displayName == name)
        #expect(type.defaultPort == port)
        #expect(type.systemImage == image)
        #expect(type.rawValue == raw)
        #expect(type.id == raw)
    }

    @Test("All Cases Count")
    func allCasesCount() {
        #expect(ArrServiceType.allCases.count == 3)
    }

    @Test("Initialization from Raw Value", arguments: [
        ("sonarr", ArrServiceType.sonarr),
        ("radarr", .radarr),
        ("prowlarr", .prowlarr),
        ("unknown", nil as ArrServiceType?)
    ])
    func initFromRawValue(rawValue: String, expected: ArrServiceType?) {
        #expect(ArrServiceType(rawValue: rawValue) == expected)
    }
}

@Suite("ArrQueueItem Computed Properties Tests")
struct ArrQueueItemTests {
    private func makeItem(
        id: Int = 1,
        title: String? = nil,
        status: String? = nil,
        trackedDownloadStatus: String? = nil,
        trackedDownloadState: String? = nil,
        statusMessages: [ArrStatusMessage]? = nil,
        size: Double? = nil,
        sizeleft: Double? = nil,
        timeleft: String? = nil
    ) throws -> ArrQueueItem {
        let json: [String: Any?] = [
            "id": id,
            "title": title,
            "status": status,
            "trackedDownloadStatus": trackedDownloadStatus,
            "trackedDownloadState": trackedDownloadState,
            "size": size,
            "sizeleft": sizeleft,
            "timeleft": timeleft
        ]
        let cleaned = json.compactMapValues { $0 }
        let data = try JSONSerialization.data(withJSONObject: cleaned)
        return try JSONDecoder().decode(ArrQueueItem.self, from: data)
    }

    @Test("Progress Calculation", arguments: [
        (nil as Double?, nil as Double?, 0.0),
        (0.0 as Double?, 0.0 as Double?, 0.0),
        (1000.0 as Double?, 500.0 as Double?, 0.5),
        (1000.0 as Double?, 0.0 as Double?, 1.0),
        (100.0 as Double?, 200.0 as Double?, 0.0),
        (500.0 as Double?, 0.0 as Double?, 1.0)
    ])
    func progressCalculation(size: Double?, sizeleft: Double?, expected: Double) throws {
        let item = try makeItem(size: size, sizeleft: sizeleft)
        #expect(item.progress == expected)
    }

    @Test("Normalized State", arguments: [
        ("Downloading" as String?, nil as String?, "downloading"),
        (nil as String?, "ImportPending" as String?, "importpending"),
        ("completed" as String?, "ImportFailed" as String?, "importfailed"),
        (nil as String?, nil as String?, "")
    ])
    func normalizedState(status: String?, trackedState: String?, expected: String) throws {
        let item = try makeItem(status: status, trackedDownloadState: trackedState)
        #expect(item.normalizedState == expected)
    }

    @Test("Downloading Status Queue Item", arguments: [
        ("downloading", true),
        ("importPending", false)
    ])
    func isDownloadingQueueItem(trackedState: String, expected: Bool) throws {
        let item = try makeItem(trackedDownloadState: trackedState)
        #expect(item.isDownloadingQueueItem == expected)
    }

    @Test("Import Issue Queue Item", arguments: [
        ("importPending" as String?, nil as String?, true),
        ("failedPending" as String?, nil as String?, true),
        (nil as String?, "warning" as String?, true),
        (nil as String?, "error" as String?, true),
        ("downloading" as String?, "ok" as String?, false)
    ])
    func isImportIssue(trackedState: String?, trackedStatus: String?, expected: Bool) throws {
        let item = try makeItem(trackedDownloadStatus: trackedStatus, trackedDownloadState: trackedState)
        #expect(item.isImportIssueQueueItem == expected)
    }

    @Test("Primary Status Message")
    func primaryStatusMessage() throws {
        let json: [String: Any] = [
            "id": 1,
            "statusMessages": [
                ["title": "t1", "messages": ["   ", "real message"]],
                ["title": "t2", "messages": ["second"]]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let item = try JSONDecoder().decode(ArrQueueItem.self, from: data)
        #expect(item.primaryStatusMessage == "real message")
    }

    @Test("Primary Status Message is Nil When Empty")
    func primaryStatusMessageNilWhenEmpty() throws {
        let item = try makeItem()
        #expect(item.primaryStatusMessage == nil)
    }
}

@Suite("ArrRelease Computed Properties Tests")
struct ArrReleaseTests {
    private func makeRelease(
        guid: String? = "test-guid",
        indexerId: Int? = 1,
        approved: Bool? = true,
        rejected: Bool? = nil,
        temporarilyRejected: Bool? = nil,
        downloadAllowed: Bool? = nil,
        ageHours: Double? = nil,
        age: Int? = nil,
        ageMinutes: Double? = nil,
        qualityName: String? = nil
    ) throws -> ArrRelease {
        var json: [String: Any] = [:]
        if let guid { json["guid"] = guid }
        if let indexerId { json["indexerId"] = indexerId }
        if let approved { json["approved"] = approved }
        if let rejected { json["rejected"] = rejected }
        if let temporarilyRejected { json["temporarilyRejected"] = temporarilyRejected }
        if let downloadAllowed { json["downloadAllowed"] = downloadAllowed }
        if let ageHours { json["ageHours"] = ageHours }
        if let age { json["age"] = age }
        if let ageMinutes { json["ageMinutes"] = ageMinutes }
        if let qualityName {
            json["quality"] = ["quality": ["name": qualityName]]
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(ArrRelease.self, from: data)
    }

    @Test("ID Combinations")
    func idCombinesGuidAndIndexer() throws {
        let release = try makeRelease(guid: "abc123", indexerId: 5)
        #expect(release.id == "abc123|5")
    }

    @Test("ID Falls Back to Title")
    func idFallsBackToTitle() throws {
        let json: [String: Any] = ["title": "SomeRelease", "indexerId": 2]
        let data = try JSONSerialization.data(withJSONObject: json)
        let release = try JSONDecoder().decode(ArrRelease.self, from: data)
        #expect(release.id == "SomeRelease|2")
    }

    @Test("ID Falls Back to release When No Guid Or Title")
    func idFallsBackToReleaseWhenNoGuidOrTitle() throws {
        let json: [String: Any] = ["indexerId": 99]
        let data = try JSONSerialization.data(withJSONObject: json)
        let release = try JSONDecoder().decode(ArrRelease.self, from: data)
        #expect(release.id == "release|99")
    }

    @Test("Can Grab Logic", arguments: [
        (true as Bool?, nil as Bool?, nil as Bool?, nil as Bool?, true),
        (nil as Bool?, nil as Bool?, nil as Bool?, false as Bool?, false),
        (nil as Bool?, true as Bool?, nil as Bool?, nil as Bool?, false),
        (nil as Bool?, nil as Bool?, true as Bool?, nil as Bool?, false),
        (nil as Bool?, nil as Bool?, nil as Bool?, nil as Bool?, true),
        (nil as Bool?, true as Bool?, nil as Bool?, false as Bool?, false)
    ])
    func canGrabLogic(approved: Bool?, rejected: Bool?, tempRejected: Bool?, allowed: Bool?, expected: Bool) throws {
        let release = try makeRelease(approved: approved, rejected: rejected, temporarilyRejected: tempRejected, downloadAllowed: allowed)
        #expect(release.canGrab == expected)
    }

    @Test("Quality Name Logic", arguments: [
        (nil as String?, "Unknown Quality"),
        ("Bluray-1080p", "Bluray-1080p")
    ])
    func qualityNameFallback(quality: String?, expected: String) throws {
        let release = try makeRelease(qualityName: quality)
        #expect(release.qualityName == expected)
    }

    @Test("Protocol Name")
    func protocolName() throws {
        let json: [String: Any] = ["protocol": "torrent"]
        let data = try JSONSerialization.data(withJSONObject: json)
        let release = try JSONDecoder().decode(ArrRelease.self, from: data)
        #expect(release.protocolName == "TORRENT")

        let unknownRelease = try makeRelease()
        #expect(unknownRelease.protocolName == "UNKNOWN")
    }

    @Test("Age Description", arguments: [
        (5.0 as Double?, nil as Int?, nil as Double?, "5h" as String?),
        (72.0 as Double?, nil as Int?, nil as Double?, "3d" as String?),
        (nil as Double?, 14 as Int?, nil as Double?, "14d" as String?),
        (nil as Double?, nil as Int?, 45.0 as Double?, "45m" as String?),
        (0.0 as Double?, 0 as Int?, 0.0 as Double?, nil as String?),
        (nil as Double?, nil as Int?, nil as Double?, nil as String?)
    ])
    func ageDescription(hours: Double?, days: Int?, minutes: Double?, expected: String?) throws {
        let release = try makeRelease(ageHours: hours, age: days, ageMinutes: minutes)
        #expect(release.ageDescription == expected)
    }

    @Test("Protocol Coding Key Mapped")
    func protocolCodingKeyMapped() throws {
        let json = #"{"protocol":"usenet","guid":"x","indexerId":1}"#
        let data = try #require(json.data(using: .utf8))
        let release = try JSONDecoder().decode(ArrRelease.self, from: data)
        #expect(release.protocol_ == "usenet")
    }

    @Test("Flexible Double Decodes")
    func flexibleDoubleDecodes() throws {
        let jsonInt = #"{"ageHours":12,"guid":"x"}"#
        let dataInt = try #require(jsonInt.data(using: .utf8))
        let releaseInt = try JSONDecoder().decode(ArrRelease.self, from: dataInt)
        #expect(releaseInt.ageHours == 12.0)

        let jsonStr = #"{"ageHours":"3.5","guid":"x"}"#
        let dataStr = try #require(jsonStr.data(using: .utf8))
        let releaseStr = try JSONDecoder().decode(ArrRelease.self, from: dataStr)
        #expect(releaseStr.ageHours == 3.5)
    }
}

@Suite("ArrReleaseSort Tests")
struct ArrReleaseSortTests {
    @Test("Default and Active Status")
    func defaultStatus() {
        var sort = ArrReleaseSort()
        #expect(sort.isFiltered == false)
        #expect(sort.isActive == false)

        sort.indexer = "MyIndexer"
        #expect(sort.isFiltered == true)
        #expect(sort.isActive == true)

        var sort2 = ArrReleaseSort()
        sort2.option = .seeders
        #expect(sort2.isActive == true)
    }

    @Test("Round Trip Raw Representable")
    func roundTripRawRepresentable() throws {
        var sort = ArrReleaseSort()
        sort.option = .age
        sort.isAscending = true
        sort.indexer = "NZBGeek"
        sort.quality = "720p"
        sort.approvedOnly = true
        sort.seasonPack = .season

        let raw = sort.rawValue
        let decoded = try #require(ArrReleaseSort(rawValue: raw))

        #expect(decoded.option == .age)
        #expect(decoded.isAscending == true)
        #expect(decoded.indexer == "NZBGeek")
        #expect(decoded.quality == "720p")
        #expect(decoded.approvedOnly == true)
        #expect(decoded.seasonPack == .season)
    }

    @Test("Invalid and Empty Raw Values")
    func invalidRawValues() {
        let sort = ArrReleaseSort(rawValue: "not valid json")
        #expect(sort?.option == .default)
        #expect(sort?.isFiltered == false)

        let sortEmpty = ArrReleaseSort(rawValue: "")
        #expect(sortEmpty?.option == .default)
    }
}

@Suite("ArrReleaseSortKey Tests")
struct ArrReleaseSortKeyTests {
    @Test("System Images", arguments: [
        (ArrReleaseSortKey.default, "square.stack"),
        (.age, "clock"),
        (.quality, "sparkles"),
        (.size, "externaldrive"),
        (.seeders, "arrow.up.circle")
    ])
    func systemImages(key: ArrReleaseSortKey, image: String) {
        #expect(key.systemImage == image)
        #expect(key.id == key.rawValue)
    }
}

@Suite("ArrDiskSpace Tests")
struct ArrDiskSpaceTests {
    @Test("Initialization")
    func initialization() {
        let disk = ArrDiskSpace(path: "/data", label: "Media", freeSpace: 100, totalSpace: 1000)
        #expect(disk.id == "/data")

        let diskNil = ArrDiskSpace(path: nil, label: "Unknown", freeSpace: 0, totalSpace: 0)
        #expect(!diskNil.id.isEmpty)
        #expect(diskNil.path == nil)
    }

    @Test("Decode and Encode")
    func encodeDecode() throws {
        let json = #"{"path":"/mnt/media","label":"Media Drive","freeSpace":5368709120,"totalSpace":107374182400}"#
        let data = try #require(json.data(using: .utf8))
        let disk = try JSONDecoder().decode(ArrDiskSpace.self, from: data)
        #expect(disk.path == "/mnt/media")
        #expect(disk.label == "Media Drive")
        #expect(disk.freeSpace == 5368709120)

        let missingJson = #"{"path":"/srv"}"#
        let missingData = try #require(missingJson.data(using: .utf8))
        let missingDisk = try JSONDecoder().decode(ArrDiskSpace.self, from: missingData)
        #expect(missingDisk.label == nil)

        let encoded = try JSONEncoder().encode(disk)
        let dict = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect(dict?["id"] == nil)
        #expect(dict?["path"] as? String == "/mnt/media")
    }
}

@Suite("ArrDiskSpaceSnapshot Tests")
struct ArrDiskSpaceSnapshotTests {
    @Test("ID Combines Service Type and Path")
    func idCombinesServiceTypeAndPath() {
        let snap = ArrDiskSpaceSnapshot(
            serviceType: .sonarr,
            path: "/data/series",
            label: nil,
            freeSpace: nil,
            totalSpace: nil
        )
        #expect(snap.id == "sonarr-/data/series")

        let snap2 = ArrDiskSpaceSnapshot(
            serviceType: .radarr,
            path: "/data/movies",
            label: "Movies",
            freeSpace: 1000,
            totalSpace: 5000
        )
        #expect(snap2.id == "radarr-/data/movies")
    }
}

@Suite("ArrHealthCheck Tests")
struct ArrHealthCheckTests {
    @Test("ID Generation")
    func idGeneration() {
        let check = ArrHealthCheck(
            source: "IndexerRssCheck",
            type: "warning",
            message: "No indexer available",
            wikiUrl: "https://wiki.example.com"
        )
        let expected = "IndexerRssCheck|warning|No indexer available|https://wiki.example.com"
        #expect(check.id == expected)

        let checkNil = ArrHealthCheck(source: nil, type: nil, message: nil, wikiUrl: nil)
        #expect(checkNil.id == "|||")
    }

    @Test("Decoding")
    func decoding() throws {
        let json = #"{"source":"TestCheck","type":"error","message":"Something failed","wikiUrl":"https://wiki.test.com"}"#
        let data = try #require(json.data(using: .utf8))
        let check = try JSONDecoder().decode(ArrHealthCheck.self, from: data)
        #expect(check.source == "TestCheck")
    }
}

@Suite("AnyCodableValue Tests")
struct AnyCodableValueTests {
    @Test("Decode String")
    func decodeString() throws {
        let json = #""hello world""#
        let data = try #require(json.data(using: .utf8))
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        guard case .string(let s) = value else {
            Issue.record("Expected .string, got \(value)")
            return
        }
        #expect(s == "hello world")
        #expect(value.displayString == "hello world")
    }

    @Test("Decode Int")
    func decodeInt() throws {
        let json = #"42"#
        let data = try #require(json.data(using: .utf8))
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        guard case .int(let i) = value else {
            Issue.record("Expected .int, got \(value)")
            return
        }
        #expect(i == 42)
        #expect(value.displayString == "42")
        #expect(value.intValue == 42)
    }

    @Test("Decode Double")
    func decodeDouble() throws {
        let json = #"3.14"#
        let data = try #require(json.data(using: .utf8))
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        switch value {
        case .double(let d):
            #expect(d == 3.14)
            #expect(value.displayString == "3.14")
            #expect(value.intValue == 3)
        case .int: break
        default: Issue.record("Unexpected case \(value)")
        }
    }

    @Test("Decode Bool")
    func decodeBool() throws {
        let json = #"true"#
        let data = try #require(json.data(using: .utf8))
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        guard case .bool(let b) = value else {
            Issue.record("Expected .bool, got \(value)")
            return
        }
        #expect(b == true)
        #expect(value.displayString == "Yes")
        #expect(value.intValue == nil)
    }

    @Test("Decode Null")
    func decodeNull() throws {
        let json = #"null"#
        let data = try #require(json.data(using: .utf8))
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        guard case .null = value else {
            Issue.record("Expected .null, got \(value)")
            return
        }
        #expect(value.displayString == nil)
        #expect(value.intValue == nil)
    }

    @Test("Decode Array")
    func decodeArray() throws {
        let json = #"[1, "two", true]"#
        let data = try #require(json.data(using: .utf8))
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        guard case .array(let arr) = value else {
            Issue.record("Expected .array, got \(value)")
            return
        }
        #expect(arr.count == 3)
        #expect(value.displayString != nil)
    }

    @Test("Display String Formatting")
    func displayStringFormatting() {
        let emptyStr = AnyCodableValue.string("")
        #expect(emptyStr.displayString == nil)

        let boolFalse = AnyCodableValue.bool(false)
        #expect(boolFalse.displayString == "No")

        let emptyArr = AnyCodableValue.array([])
        #expect(emptyArr.displayString == nil)

        let arr = AnyCodableValue.array([.string("a"), .string("b")])
        #expect(arr.displayString == "a, b")

        let htmlVal = AnyCodableValue.string("<b>Bold</b> text &amp; more")
        let display = htmlVal.displayString
        #expect(display?.contains("<b>") == false)
        #expect(display?.contains("&amp;") == false)
        #expect(display?.contains("Bold") == true)
        #expect(display?.contains("&") == true)
    }

    @Test("Encode and Decode Round Trip")
    func encodeAndDecodeRoundTrip() throws {
        let original = AnyCodableValue.string("round-trip")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        #expect(decoded.displayString == "round-trip")
    }
}

@Suite("Prowlarr Tests")
struct ProwlarrTests {
    @Test("Protocol Properties", arguments: [
        (ProwlarrIndexerProtocol.usenet, "Usenet", false, "envelope.circle"),
        (.torrent, "Torrent", true, "arrow.down.circle")
    ])
    func protocolProperties(proto: ProwlarrIndexerProtocol, name: String, isTorrent: Bool, image: String) {
        #expect(proto.displayName == name)
        #expect(proto.isTorrent == isTorrent)
        #expect(proto.systemImage == image)
    }

    @Test("Indexer Schema List ID")
    func indexerSchemaListID() {
        let indexer1 = ProwlarrIndexer(
            id: 5, name: "NZBGeek", enable: true, implementation: nil, implementationName: nil,
            configContract: nil, infoLink: nil, tags: nil, priority: nil, appProfileId: nil,
            shouldSearch: nil, supportsRss: nil, supportsSearch: nil, protocol: nil, fields: nil
        )
        #expect(indexer1.schemaListID == "indexer-5")

        let indexer2 = ProwlarrIndexer(
            id: 0, name: "NZBGeek", enable: false, implementation: "NZBGeekSettings",
            implementationName: "NZBGeek", configContract: nil, infoLink: nil, tags: nil,
            priority: nil, appProfileId: nil, shouldSearch: nil, supportsRss: nil, supportsSearch: nil,
            protocol: nil, fields: nil
        )
        let id2 = indexer2.schemaListID
        #expect(id2.hasPrefix("template-"))

        let indexer3 = ProwlarrIndexer(
            id: 0, name: nil, enable: false, implementation: nil, implementationName: nil,
            configContract: nil, infoLink: nil, tags: nil, priority: nil, appProfileId: nil,
            shouldSearch: nil, supportsRss: nil, supportsSearch: nil, protocol: nil, fields: nil
        )
        #expect(indexer3.schemaListID.hasPrefix("template-unknown-"))
    }

    private func makeResult(
        guid: String? = nil,
        title: String? = nil,
        indexerId: Int? = nil,
        downloadUrl: String? = nil,
        downloadVolumeFactor: Double? = nil,
        protocol_: String? = nil
    ) throws -> ProwlarrSearchResult {
        var json: [String: Any] = [:]
        if let guid { json["guid"] = guid }
        if let title { json["title"] = title }
        if let indexerId { json["indexerId"] = indexerId }
        if let downloadUrl { json["downloadUrl"] = downloadUrl }
        if let downloadVolumeFactor { json["downloadVolumeFactor"] = downloadVolumeFactor }
        if let protocol_ { json["protocol"] = protocol_ }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(ProwlarrSearchResult.self, from: data)
    }

    @Test("Search Result IDs")
    func searchResultID() throws {
        let result1 = try makeResult(guid: "my-unique-guid")
        #expect(result1.id == "my-unique-guid")

        let result2 = try makeResult(title: "Release Name", indexerId: 3)
        #expect(result2.id.hasPrefix("search-result-"))

        let result3 = try makeResult()
        #expect(result3.id.hasPrefix("search-result-unknown-"))
    }

    @Test("Search Result Properties", arguments: [
        // volumeFactor, proto, url, isFreeleech, isTorrent, isMagnet
        (0.0, "torrent", "magnet:?xt=abc", true, true, true),
        (1.0, "usenet", "https://example.com/nzb", false, false, false)
    ])
    func searchResultProperties(factor: Double, proto: String, url: String, free: Bool, torrent: Bool, magnet: Bool) throws {
        let result = try makeResult(downloadUrl: url, downloadVolumeFactor: factor, protocol_: proto)
        #expect(result.isFreeleech == free)
        #expect(result.isTorrent == torrent)
        #expect(result.isMagnet == magnet)
    }

    private func makeEntry(
        indexerId: Int? = nil,
        indexerName: String? = nil,
        averageResponseTime: Double? = nil,
        numberOfQueries: Int? = nil,
        numberOfFailedQueries: Int? = nil
    ) throws -> ProwlarrIndexerStatEntry {
        var json: [String: Any] = [:]
        if let indexerId { json["indexerId"] = indexerId }
        if let indexerName { json["indexerName"] = indexerName }
        if let averageResponseTime { json["averageResponseTime"] = averageResponseTime }
        if let numberOfQueries { json["numberOfQueries"] = numberOfQueries }
        if let numberOfFailedQueries { json["numberOfFailedQueries"] = numberOfFailedQueries }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(ProwlarrIndexerStatEntry.self, from: data)
    }

    @Test("Indexer Stat Entry")
    func indexerStatEntry() throws {
        let entry1 = try makeEntry(indexerId: 10)
        #expect(entry1.id == "indexer-10")

        let entry2 = try makeEntry(indexerName: "NZBGeek")
        #expect(entry2.id == "indexer-unknown-NZBGeek")

        let entry3 = try makeEntry(numberOfQueries: 100, numberOfFailedQueries: 20)
        #expect(entry3.successRate == 0.8)

        let entry4 = try makeEntry(averageResponseTime: 256.7)
        #expect(entry4.avgResponseTimeFormatted == "257ms")
    }

    @Test("Search Type Properties", arguments: [
        (ProwlarrSearchType.search, "All", "magnifyingglass"),
        (.tvsearch, "TV", "tv"),
        (.moviesearch, "Movies", "film"),
        (.audiosearch, "Audio", "music.note")
    ])
    func searchTypeProperties(type: ProwlarrSearchType, name: String, image: String) {
        #expect(type.displayName == name)
        #expect(type.systemImage == image)
        #expect(type.id == type.rawValue)
    }
}

@Suite("ArrServiceManager Tests")
@MainActor
struct ArrServiceManagerTests {
    @Test("Initial State")
    func initialState() {
        let manager = ArrServiceManager()
        #expect(manager.sonarrInstances.isEmpty)
        #expect(manager.radarrInstances.isEmpty)
        #expect(manager.prowlarrClient == nil)
        #expect(manager.prowlarrConnected == false)
        #expect(manager.sonarrConnected == false)
        #expect(manager.radarrConnected == false)
        #expect(manager.isInitializing == false)
        #expect(manager.isLoadingHealth == false)
    }

    @Test("Disconnect All")
    func disconnectAll() {
        let manager = ArrServiceManager()
        manager.disconnectAll()
        #expect(manager.sonarrInstances.isEmpty)
        #expect(manager.prowlarrClient == nil)
        #expect(manager.sonarrBlocklist.isEmpty)
    }

    @Test("Set Active Profiles")
    func setActiveProfiles() {
        let manager = ArrServiceManager()
        let uuid = UUID()
        manager.setActiveSonarr(uuid)
        #expect(manager.activeSonarrProfileID == uuid)

        let radarrUuid = UUID()
        manager.setActiveRadarr(radarrUuid)
        #expect(manager.activeRadarrProfileID == radarrUuid)
    }

    @Test("Clear Blocklist")
    func clearBlocklist() async {
        let manager = ArrServiceManager()
        await manager.clearBlocklist(sonarrIDs: [], radarrIDs: [])
        #expect(manager.sonarrBlocklist.isEmpty)
        #expect(manager.radarrBlocklist.isEmpty)
    }
}

@Suite("Arr API Client Tests")
struct ArrAPIClientTests {
    @Test("Default Page Size")
    func defaultPageSize() {
        #expect(ArrAPIClient.defaultPageSize == 20)
    }

    @Test("URL Trimming", arguments: [
        ("http://localhost:8989/", "http://localhost:8989"),
        ("  http://localhost:8989  ", "http://localhost:8989"),
        ("  http://localhost:8989/  ", "http://localhost:8989"),
        ("http://localhost:8989", "http://localhost:8989")
    ])
    func urlTrimming(input: String, expected: String) async {
        let client = ArrAPIClient(baseURL: input, apiKey: "testkey")
        let baseURL = await client.baseURL
        #expect(baseURL == expected)
    }
}

@Suite("Miscellaneous Parsing Tests")
struct MiscellaneousParsingTests {
    @Test("Queue Item Coding Keys")
    func queueItemCodingKeys() throws {
        let json = #"""
        {
          "id": 42, "title": "Test Episode", "status": "downloading",
          "trackedDownloadStatus": "ok", "trackedDownloadState": "downloading",
          "protocol": "torrent", "downloadClient": "qBittorrent", "size": 2000.0,
          "sizeleft": 1000.0, "timeleft": "00:30:00", "seriesId": 5, "episodeId": 10,
          "seasonNumber": 2, "movieId": null
        }
        """#
        let data = try #require(json.data(using: .utf8))
        let item = try JSONDecoder().decode(ArrQueueItem.self, from: data)
        #expect(item.id == 42)
        #expect(item.protocol_ == "torrent")
        #expect(item.progress == 0.5)
        #expect(item.timeleft == "00:30:00")
    }

    @Test("ArrQueuePage Decoding")
    func queuePageDecoding() throws {
        let json = #"{"page": 1, "pageSize": 10, "totalRecords": 1, "records": [{"id": 99}]}"#
        let data = try #require(json.data(using: .utf8))
        let page = try JSONDecoder().decode(ArrQueuePage.self, from: data)
        #expect(page.records?.count == 1)
        #expect(page.records?.first?.id == 99)
    }

    @Test("ArrHistoryPage Decoding")
    func historyPageDecoding() throws {
        let json = #"{"page": 1, "pageSize": 20, "totalRecords": 2, "records": [{"id": 1, "eventType": "grabbed", "sourceTitle": "Show.S01E01"}]}"#
        let data = try #require(json.data(using: .utf8))
        let page = try JSONDecoder().decode(ArrHistoryPage.self, from: data)
        #expect(page.totalRecords == 2)
        #expect(page.records?.first?.eventType == "grabbed")
    }

    @Test("ArrBlocklistPage Decoding")
    func blocklistPageDecoding() throws {
        let json = #"{"page": 1, "pageSize": 20, "totalRecords": 1, "records": [{"id": 5, "sourceTitle": "Bad.Release.HDTV"}]}"#
        let data = try #require(json.data(using: .utf8))
        let page = try JSONDecoder().decode(ArrBlocklistPage.self, from: data)
        #expect(page.totalRecords == 1)
        #expect(page.records?.first?.id == 5)
    }

    @Test("ArrSystemStatus Decoding")
    func systemStatusDecoding() throws {
        let json = #"{"appName": "Sonarr", "instanceName": "MyInstance", "version": "4.0.0", "osName": "linux", "isDocker": true}"#
        let data = try #require(json.data(using: .utf8))
        let status = try JSONDecoder().decode(ArrSystemStatus.self, from: data)
        #expect(status.appName == "Sonarr")
        #expect(status.version == "4.0.0")
    }

    @Test("ArrQualityProfile Decoding")
    func qualityProfileDecoding() throws {
        let json = #"{"id": 1, "name": "Any", "upgradeAllowed": true, "cutoff": 5, "items": []}"#
        let data = try #require(json.data(using: .utf8))
        let profile = try JSONDecoder().decode(ArrQualityProfile.self, from: data)
        #expect(profile.name == "Any")
        #expect(profile.upgradeAllowed == true)
    }

    @Test("ArrRootFolder Decoding")
    func rootFolderDecoding() throws {
        let json = #"{"id": 1, "path": "/data/media/tv", "accessible": true, "freeSpace": 500000000000}"#
        let data = try #require(json.data(using: .utf8))
        let folder = try JSONDecoder().decode(ArrRootFolder.self, from: data)
        #expect(folder.path == "/data/media/tv")
    }

    @Test("ArrTag Decoding")
    func tagDecoding() throws {
        let json = #"{"id": 3, "label": "4k"}"#
        let data = try #require(json.data(using: .utf8))
        let tag = try JSONDecoder().decode(ArrTag.self, from: data)
        #expect(tag.label == "4k")
    }
}

// MARK: - New tests for PR: ArrStack quality-profile CRUD, command polling, manual-import helpers

@Suite("ArrCommand Computed Property Tests")
struct ArrCommandTests {
    private func makeCommand(status: String?) throws -> ArrCommand {
        var json: [String: Any] = ["id": 42]
        if let status { json["status"] = status }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(ArrCommand.self, from: data)
    }

    // isTerminal — all five terminal statuses
    @Test("isTerminal returns true for terminal statuses", arguments: [
        "completed", "failed", "aborted", "cancelled", "orphaned"
    ])
    func isTerminalForTerminalStatuses(status: String) throws {
        let command = try makeCommand(status: status)
        #expect(command.isTerminal == true)
    }

    // isTerminal — non-terminal statuses
    @Test("isTerminal returns false for non-terminal statuses", arguments: [
        "queued" as String?, "started", nil
    ])
    func isNotTerminalForNonTerminalStatuses(status: String?) throws {
        let command = try makeCommand(status: status)
        #expect(command.isTerminal == false)
    }

    // succeeded — only "completed" maps to true
    @Test("succeeded is true only for completed", arguments: [
        ("completed", true),
        ("failed", false),
        ("aborted", false),
        ("cancelled", false),
        ("orphaned", false),
        ("queued", false)
    ])
    func succeededForStatus(status: String, expected: Bool) throws {
        let command = try makeCommand(status: status)
        #expect(command.succeeded == expected)
    }

    @Test("succeeded is false when status is nil")
    func succeededWhenStatusNil() throws {
        let command = try makeCommand(status: nil)
        #expect(command.succeeded == false)
    }

    @Test("ArrCommand decodes id and exception fields")
    func decodesIdAndException() throws {
        let json = #"{"id":7,"name":"ManualImport","status":"failed","exception":"File not found"}"#
        let data = try #require(json.data(using: .utf8))
        let command = try JSONDecoder().decode(ArrCommand.self, from: data)
        #expect(command.id == 7)
        #expect(command.exception == "File not found")
        #expect(command.isTerminal == true)
        #expect(command.succeeded == false)
    }

    @Test("ArrCommand with nil id decodes without crashing")
    func nilIdDecodes() throws {
        let json = #"{"status":"queued"}"#
        let data = try #require(json.data(using: .utf8))
        let command = try JSONDecoder().decode(ArrCommand.self, from: data)
        #expect(command.id == nil)
        #expect(command.isTerminal == false)
    }

    @Test("ArrCommand round-trip encode/decode preserves status")
    func roundTripEncoding() throws {
        let original = try makeCommand(status: "completed")
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ArrCommand.self, from: encoded)
        #expect(decoded.status == "completed")
        #expect(decoded.isTerminal == true)
        #expect(decoded.succeeded == true)
    }
}

@Suite("ArrError commandTimeout Description Tests")
struct ArrErrorCommandTimeoutTests {
    @Test("commandTimeout with status in lastKnownCommand")
    func descriptionWithStatus() throws {
        let json = #"{"id":99,"status":"failed"}"#
        let data = try #require(json.data(using: .utf8))
        let command = try JSONDecoder().decode(ArrCommand.self, from: data)
        let error = ArrError.commandTimeout(commandId: 99, lastKnownCommand: command)
        let desc = try #require(error.errorDescription)
        #expect(desc.contains("99"))
        #expect(desc.contains("failed"))
        #expect(desc.contains("timed out"))
    }

    @Test("commandTimeout without lastKnownCommand")
    func descriptionWithoutCommand() {
        let error = ArrError.commandTimeout(commandId: 5, lastKnownCommand: nil)
        let desc = error.errorDescription ?? ""
        #expect(desc.contains("5"))
        #expect(desc.contains("did not finish") || desc.contains("timeout"))
    }

    @Test("commandTimeout with nil commandId")
    func descriptionWithNilCommandId() {
        let error = ArrError.commandTimeout(commandId: nil, lastKnownCommand: nil)
        let desc = error.errorDescription ?? ""
        // Should not crash; should contain a sentinel like -1
        #expect(!desc.isEmpty)
    }

    @Test("commandTimeout with command having nil status")
    func descriptionWithCommandNilStatus() throws {
        let json = #"{"id":12}"#
        let data = try #require(json.data(using: .utf8))
        let command = try JSONDecoder().decode(ArrCommand.self, from: data)
        let error = ArrError.commandTimeout(commandId: 12, lastKnownCommand: command)
        let desc = error.errorDescription ?? ""
        // When status is nil, falls back to the "did not finish" message
        #expect(desc.contains("did not finish") || desc.contains("timeout") || desc.contains("12"))
    }
}

@Suite("ArrQualityProfile Encoding Tests (CRUD)")
struct ArrQualityProfileCRUDTests {
    private func makeProfile(id: Int = 1, name: String = "HD-1080p", upgradeAllowed: Bool = true, cutoff: Int = 5) -> ArrQualityProfile {
        ArrQualityProfile(id: id, name: name, upgradeAllowed: upgradeAllowed, cutoff: cutoff, items: nil)
    }

    @Test("ArrQualityProfile encodes id and name (required for PUT body)")
    func encodesIdAndName() throws {
        let profile = makeProfile(id: 3, name: "4K-HDR")
        let data = try JSONEncoder().encode(profile)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(dict?["id"] as? Int == 3)
        #expect(dict?["name"] as? String == "4K-HDR")
    }

    @Test("ArrQualityProfile round-trip preserves all fields")
    func roundTrip() throws {
        let json = #"{"id":7,"name":"WEB-DL","upgradeAllowed":false,"cutoff":3,"items":[]}"#
        let data = try #require(json.data(using: .utf8))
        let profile = try JSONDecoder().decode(ArrQualityProfile.self, from: data)
        #expect(profile.id == 7)
        #expect(profile.name == "WEB-DL")
        #expect(profile.upgradeAllowed == false)
        #expect(profile.cutoff == 3)
        #expect(profile.items?.isEmpty == true)

        let reencoded = try JSONEncoder().encode(profile)
        let redict = try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        #expect(redict?["id"] as? Int == 7)
        #expect(redict?["name"] as? String == "WEB-DL")
    }

    @Test("ArrQualityProfile with nested quality items encodes items array")
    func encodesItems() throws {
        let quality = ArrQuality(id: 10, name: "Bluray-1080p", source: nil, resolution: 1080)
        let item = ArrQualityProfileItem(quality: quality, allowed: true, items: nil)
        let profile = ArrQualityProfile(id: 2, name: "Bluray", upgradeAllowed: true, cutoff: 10, items: [item])
        let data = try JSONEncoder().encode(profile)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let items = dict?["items"] as? [[String: Any]]
        #expect(items?.count == 1)
        #expect(items?.first?["allowed"] as? Bool == true)
    }

    @Test("ArrQualityProfile id mutability allows update flow")
    func idMutability() {
        var profile = makeProfile(id: 0, name: "New Profile")
        // Simulates server assigning an id after create
        profile.id = 99
        #expect(profile.id == 99)
    }

    @Test("ArrQualityProfile decoding with missing optional fields")
    func decodingMissingOptionals() throws {
        let json = #"{"id":1,"name":"Any"}"#
        let data = try #require(json.data(using: .utf8))
        let profile = try JSONDecoder().decode(ArrQualityProfile.self, from: data)
        #expect(profile.name == "Any")
        #expect(profile.upgradeAllowed == nil)
        #expect(profile.cutoff == nil)
        #expect(profile.items == nil)
    }
}

@Suite("JSONValue Codable Tests")
struct JSONValueTests {
    @Test("Decodes string")
    func decodesString() throws {
        let json = #""hello""#
        let data = try #require(json.data(using: .utf8))
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .string(let s) = value else {
            Issue.record("Expected .string, got \(value)")
            return
        }
        #expect(s == "hello")
    }

    @Test("Decodes number")
    func decodesNumber() throws {
        let json = #"3.14"#
        let data = try #require(json.data(using: .utf8))
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .number(let n) = value else {
            Issue.record("Expected .number, got \(value)")
            return
        }
        #expect(abs(n - 3.14) < 0.0001)
    }

    @Test("Decodes bool true and false", arguments: [
        (#"true"#, true),
        (#"false"#, false)
    ])
    func decodesBool(json: String, expected: Bool) throws {
        let data = try #require(json.data(using: .utf8))
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .bool(let b) = value else {
            Issue.record("Expected .bool, got \(value)")
            return
        }
        #expect(b == expected)
    }

    @Test("Decodes null")
    func decodesNull() throws {
        let json = #"null"#
        let data = try #require(json.data(using: .utf8))
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .null = value else {
            Issue.record("Expected .null, got \(value)")
            return
        }
    }

    @Test("Decodes object")
    func decodesObject() throws {
        let json = #"{"key":"value","count":42}"#
        let data = try #require(json.data(using: .utf8))
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let dict) = value else {
            Issue.record("Expected .object, got \(value)")
            return
        }
        #expect(dict.count == 2)
        if case .string(let s) = dict["key"] { #expect(s == "value") } else { Issue.record("Missing 'key'") }
        if case .number(let n) = dict["count"] { #expect(Int(n) == 42) } else { Issue.record("Missing 'count'") }
    }

    @Test("Decodes array")
    func decodesArray() throws {
        let json = #"["a",1,true,null]"#
        let data = try #require(json.data(using: .utf8))
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .array(let arr) = value else {
            Issue.record("Expected .array, got \(value)")
            return
        }
        #expect(arr.count == 4)
        guard case .string(let s) = arr[0] else { Issue.record("arr[0] not string"); return }
        #expect(s == "a")
        guard case .null = arr[3] else { Issue.record("arr[3] not null"); return }
    }

    @Test("Encodes and decodes string round-trip")
    func stringRoundTrip() throws {
        let original = JSONValue.string("round-trip test")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .string(let s) = decoded else { Issue.record("Expected .string"); return }
        #expect(s == "round-trip test")
    }

    @Test("Encodes and decodes null round-trip")
    func nullRoundTrip() throws {
        let original = JSONValue.null
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .null = decoded else { Issue.record("Expected .null"); return }
    }

    @Test("Encodes and decodes object round-trip")
    func objectRoundTrip() throws {
        let original = JSONValue.object(["name": .string("Sonarr"), "port": .number(8989), "enabled": .bool(true)])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let dict) = decoded else { Issue.record("Expected .object"); return }
        #expect(dict.count == 3)
        if case .string(let s) = dict["name"] { #expect(s == "Sonarr") } else { Issue.record("name mismatch") }
        if case .number(let n) = dict["port"] { #expect(Int(n) == 8989) } else { Issue.record("port mismatch") }
        if case .bool(let b) = dict["enabled"] { #expect(b == true) } else { Issue.record("enabled mismatch") }
    }

    @Test("rawValue returns correct Swift types")
    func rawValues() {
        #expect(JSONValue.string("x").rawValue as? String == "x")
        #expect(JSONValue.number(2.5).rawValue as? Double == 2.5)
        #expect(JSONValue.bool(false).rawValue as? Bool == false)
        #expect(JSONValue.null.rawValue is NSNull)
        let arr = JSONValue.array([.string("a")])
        #expect((arr.rawValue as? [Any])?.count == 1)
        let obj = JSONValue.object(["k": .string("v")])
        #expect((obj.rawValue as? [String: Any])?["k"] as? String == "v")
    }

    @Test("Nested object with array decodes correctly")
    func nestedObjectWithArray() throws {
        let json = #"{"files":[{"path":"/media/movie.mkv","size":1234567890}]}"#
        let data = try #require(json.data(using: .utf8))
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let outer) = value,
              case .array(let files) = outer["files"],
              case .object(let file) = files.first,
              case .string(let path) = file["path"] else {
            Issue.record("Unexpected structure")
            return
        }
        #expect(path == "/media/movie.mkv")
    }

    @Test("importJSON-style mutation: sets movieId key in object")
    func objectKeyMutation() throws {
        // Simulate the importJSON(service:) logic for Radarr
        let json = #"{"path":"/media/movie.mkv","size":100}"#
        let data = try #require(json.data(using: .utf8))
        let original = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(var dict) = original else {
            Issue.record("Expected .object")
            return
        }
        let mediaID = 42
        dict["movieId"] = .number(Double(mediaID))
        let mutated = JSONValue.object(dict)

        guard case .object(let result) = mutated,
              case .number(let n) = result["movieId"] else {
            Issue.record("movieId not set")
            return
        }
        #expect(Int(n) == 42)
    }
}

@Suite("ArrError unsupportedNotificationsService Tests")
struct ArrErrorUnsupportedNotificationsTests {
    @Test("unsupportedNotificationsService includes service name in description")
    func includesServiceName() {
        let error = ArrError.unsupportedNotificationsService("Prowlarr")
        let desc = error.errorDescription ?? ""
        #expect(desc.contains("Prowlarr"))
        #expect(desc.contains("not support") || desc.contains("does not support"))
    }
}

@Suite("ArrQueueItem outputPath Tests")
struct ArrQueueItemOutputPathTests {
    @Test("outputPath decodes when present")
    func decodesOutputPath() throws {
        let json = #"{"id":1,"outputPath":"/downloads/Movie.2024"}"#
        let data = try #require(json.data(using: .utf8))
        let item = try JSONDecoder().decode(ArrQueueItem.self, from: data)
        #expect(item.outputPath == "/downloads/Movie.2024")
    }

    @Test("outputPath is nil when absent")
    func nilWhenAbsent() throws {
        let json = #"{"id":2}"#
        let data = try #require(json.data(using: .utf8))
        let item = try JSONDecoder().decode(ArrQueueItem.self, from: data)
        #expect(item.outputPath == nil)
    }

    @Test("items with warning trackedDownloadStatus and outputPath are import candidates")
    func warningStatusWithOutputPath() throws {
        let json = #"{"id":3,"trackedDownloadStatus":"warning","outputPath":"/downloads/Show.S01E01"}"#
        let data = try #require(json.data(using: .utf8))
        let item = try JSONDecoder().decode(ArrQueueItem.self, from: data)
        #expect(item.trackedDownloadStatus == "warning")
        #expect(item.outputPath == "/downloads/Show.S01E01")
        #expect(item.isImportIssueQueueItem == true)
    }

    @Test("items with error trackedDownloadStatus and outputPath are import candidates")
    func errorStatusWithOutputPath() throws {
        let json = #"{"id":4,"trackedDownloadStatus":"error","outputPath":"/downloads/Movie"}"#
        let data = try #require(json.data(using: .utf8))
        let item = try JSONDecoder().decode(ArrQueueItem.self, from: data)
        #expect(item.trackedDownloadStatus == "error")
        #expect(item.outputPath == "/downloads/Movie")
        #expect(item.isImportIssueQueueItem == true)
    }
}
