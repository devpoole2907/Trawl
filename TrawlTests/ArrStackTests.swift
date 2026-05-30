import Testing
import Foundation
@testable import Trawl

@Suite("ArrError Tests")
@MainActor
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

    @Test("Server Error Description Extracts Servarr JSON Message")
    func serverErrorDescriptionExtractsServarrJSONMessage() {
        let body = """
        {
          "message": "Download client failed to add torrent by url",
          "description": "Download client failed to add torrent by url\\n   at NzbDrone.Core.Download.Clients.QBittorrent.QBittorrentProxyV2.AddTorrentFromUrl()"
        }
        """

        let error = ArrError.serverError(statusCode: 500, message: body)

        #expect(error.errorDescription == "Server error (500): The download client rejected this release. If it was already downloaded and deleted, remove the old torrent from your download client or choose another release, then try again.")
    }

    @Test("Server Error Description Strips Stack Trace From Description")
    func serverErrorDescriptionStripsStackTraceFromDescription() {
        let body = """
        {
          "description": "Indexer request failed\\n   at NzbDrone.Core.Indexers.Fetch()"
        }
        """

        let error = ArrError.serverError(statusCode: 500, message: body)

        #expect(error.errorDescription == "Server error (500): Indexer request failed")
    }
}

@Suite("ArrServiceType Tests")
@MainActor
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

@Suite("Remote Filesystem Tests")
@MainActor
struct RemoteFileSystemTests {
    @Test("Arr filesystem entries decode and map directories and files")
    func arrFileSystemEntryDecode() throws {
        let data = """
        [
            { "name": "Media", "path": "/media", "type": "folder", "isDirectory": true, "isFile": false },
            { "name": "sample.mkv", "path": "/media/sample.mkv", "type": "file", "isDirectory": false, "isFile": true }
        ]
        """.data(using: .utf8)!

        let entries = try JSONDecoder().decode([ArrFileSystemEntry].self, from: data)

        #expect(entries[0].remotePathEntry.name == "Media")
        #expect(entries[0].remotePathEntry.path == "/media")
        #expect(entries[0].remotePathEntry.kind == .directory)
        #expect(entries[0].remotePathEntry.isDirectory)
        #expect(entries[1].remotePathEntry.kind == .file)
        #expect(!entries[1].remotePathEntry.isDirectory)
    }

    @Test("Arr filesystem query construction")
    func arrFileSystemQueryItems() {
        let items = ArrAPIClient.fileSystemQueryItems(path: "/media", includeFiles: false)
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })

        #expect(values["path"] == "/media")
        #expect(values["allowFoldersWithoutTrailingSlashes"] == "true")
        #expect(values["includeFiles"] == "false")
    }

    @Test("Jellyfin filesystem entries decode drive network directory and file cases")
    func jellyfinFileSystemEntryDecode() throws {
        let data = """
        [
            { "Name": "Media", "Path": "/media", "Type": "Directory" },
            { "Name": "C:", "Path": "C:\\\\", "Type": "Drive" },
            { "Name": "NAS", "Path": "\\\\\\\\nas\\\\media", "Type": "NetworkShare" },
            { "Name": "sample.mkv", "Path": "/media/sample.mkv", "Type": "File" }
        ]
        """.data(using: .utf8)!

        let entries = try JSONDecoder().decode([JellyfinFileSystemEntryInfo].self, from: data)

        #expect(entries[0].remotePathEntry.kind == .directory)
        #expect(entries[1].remotePathEntry.kind == .drive)
        #expect(entries[2].remotePathEntry.kind == .networkShare)
        #expect(entries[3].remotePathEntry.kind == .file)
        #expect(!entries[3].remotePathEntry.isDirectory)
    }

    @Test("Jellyfin directory contents query construction")
    func jellyfinDirectoryContentsQueryParams() {
        let values = JellyfinAPIClient.directoryContentsParams(
            path: "/media",
            includeFiles: false,
            includeDirectories: true
        )

        #expect(values["Path"] == "/media")
        #expect(values["IncludeFiles"] == "false")
        #expect(values["IncludeDirectories"] == "true")
    }
}

@Suite("ArrQueueItem Computed Properties Tests")
@MainActor
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
@MainActor
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

    @Test("Torrent Info Hash Extracted From Magnet")
    func torrentInfoHashExtractedFromMagnet() throws {
        let hash = "0123456789abcdef0123456789abcdef01234567"
        let json = #"{"magnetUrl":"magnet:?xt=urn:btih:\#(hash)&dn=Release","guid":"x","indexerId":1}"#
        let data = try #require(json.data(using: .utf8))
        let release = try JSONDecoder().decode(ArrRelease.self, from: data)

        #expect(release.torrentInfoHash == hash)
    }

    @Test("Torrent Info Hash Extracted From Encoded Guid")
    func torrentInfoHashExtractedFromEncodedGuid() throws {
        let hash = "abcdefabcdefabcdefabcdefabcdefabcdefabcd"
        let json = #"{"guid":"magnet%3A%3Fxt%3Durn%3Abtih%3A\#(hash)%26dn%3DRelease","indexerId":1}"#
        let data = try #require(json.data(using: .utf8))
        let release = try JSONDecoder().decode(ArrRelease.self, from: data)

        #expect(release.torrentInfoHash == hash)
    }
}

@Suite("ArrReleaseSort Tests")
@MainActor
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
@MainActor
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
@MainActor
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
@MainActor
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
@MainActor
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
@MainActor
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
@MainActor
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

    private func makeStatus(indexerId: Int, disabledTill: String?) throws -> ProwlarrIndexerStatus {
        var json: [String: Any] = [
            "id": indexerId,
            "indexerId": indexerId,
        ]
        if let disabledTill {
            json["disabledTill"] = disabledTill
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(ProwlarrIndexerStatus.self, from: data)
    }

    @Test("Temporary disable status affects availability")
    func temporaryDisableStatusAffectsAvailability() throws {
        let indexer = ProwlarrIndexer(
            id: 5, name: "NZBGeek", enable: true, implementation: nil, implementationName: nil,
            configContract: nil, infoLink: nil, tags: nil, priority: nil, appProfileId: nil,
            shouldSearch: nil, supportsRss: nil, supportsSearch: nil, protocol: nil, fields: nil
        )
        let status = try makeStatus(indexerId: indexer.id, disabledTill: "2099-01-01T00:00:00Z")
        let viewModel = ProwlarrViewModel(previewIndexers: [indexer], indexerStatuses: [status])

        #expect(viewModel.isIndexerTemporarilyDisabled(id: indexer.id))
        #expect(!viewModel.isIndexerAvailable(indexer))
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
@MainActor
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
@MainActor
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

    @Test("Manual Import Imported Episode Keys")
    func manualImportImportedEpisodeKeys() throws {
        let json = #"""
        {
          "path": "/downloads/Better.Call.Saul.S02E01-E02.mkv",
          "seasonNumber": 2,
          "episodes": [
            { "episodeNumber": 1, "title": "Switch" },
            { "episodeNumber": 2, "title": "Cobbler" }
          ]
        }
        """#
        let data = try #require(json.data(using: .utf8))
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        let item = try #require(ManualImportItem(json: value))

        let keys = ManualImportScanViewModel.importedEpisodeKeys(from: [item])

        #expect(keys == [
            ManualImportEpisodeKey(seasonNumber: 2, episodeNumber: 1),
            ManualImportEpisodeKey(seasonNumber: 2, episodeNumber: 2)
        ])
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

    @Test("Arr History Event Display Names")
    func historyEventDisplayNames() {
        #expect(ArrHistoryEventFormatter.displayName(for: "indexerRssQuery") == "Indexer RSS Query")
        #expect(ArrHistoryEventFormatter.displayName(for: "indexerQuery") == "Indexer Query")
        #expect(ArrHistoryEventFormatter.displayName(for: "releaseGrabbed") == "Release Grabbed")
        #expect(ArrHistoryEventFormatter.displayName(for: "customAPIEvent") == "Custom API Event")
        #expect(ArrHistoryEventFormatter.displayName(for: nil) == "Event")
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

    @Test("ArrQualityProfile preserves group and format payload fields")
    func qualityProfilePreservesSavePayloadFields() throws {
        let json = #"""
        {
            "id": 1,
            "name": "Any",
            "upgradeAllowed": true,
            "cutoff": 1000,
            "items": [
                {
                    "id": 1000,
                    "name": "WEB 1080p",
                    "allowed": true,
                    "items": [
                        {
                            "quality": {
                                "id": 3,
                                "name": "WEBDL-1080p",
                                "source": "web",
                                "resolution": 1080
                            },
                            "allowed": true
                        }
                    ]
                }
            ],
            "minFormatScore": 10,
            "cutoffFormatScore": 20,
            "minUpgradeFormatScore": 5,
            "formatItems": [
                {
                    "format": 7,
                    "name": "HDR",
                    "score": 100
                }
            ],
            "language": {
                "id": 1,
                "name": "English"
            }
        }
        """#
        let data = try #require(json.data(using: .utf8))
        let profile = try JSONDecoder().decode(ArrQualityProfile.self, from: data)
        let group = try #require(profile.items?.first)
        let formatItem = try #require(profile.formatItems?.first)

        #expect(group.id == 1000)
        #expect(group.name == "WEB 1080p")
        #expect(formatItem.format == 7)
        #expect(formatItem.score == 100)
        #expect(profile.language?.name == "English")

        let encoded = try JSONEncoder().encode(profile)
        let payload = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let encodedItems = try #require(payload["items"] as? [[String: Any]])
        let encodedGroup = try #require(encodedItems.first)
        let encodedFormatItems = try #require(payload["formatItems"] as? [[String: Any]])
        let encodedLanguage = try #require(payload["language"] as? [String: Any])

        #expect(encodedGroup["id"] as? Int == 1000)
        #expect(encodedGroup["name"] as? String == "WEB 1080p")
        #expect(encodedFormatItems.first?["format"] as? Int == 7)
        #expect(encodedLanguage["name"] as? String == "English")
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

    @Test("Bazarr page defaults total to data count when omitted")
    func bazarrPageDefaultsMissingTotal() throws {
        let json = #"""
        {
            "data": [
                {
                    "timestamp": "2026-05-18 09:30:00",
                    "type": "INFO",
                    "message": "Bazarr started"
                }
            ]
        }
        """#
        let data = try #require(json.data(using: .utf8))
        let page = try JSONDecoder().decode(BazarrPage<BazarrLogEntry>.self, from: data)

        #expect(page.total == 1)
        #expect(page.data.first?.message == "Bazarr started")
    }

    @Test("Bazarr page preserves explicit total")
    func bazarrPagePreservesExplicitTotal() throws {
        let json = #"{"data": [], "total": 42}"#
        let data = try #require(json.data(using: .utf8))
        let page = try JSONDecoder().decode(BazarrPage<BazarrLogEntry>.self, from: data)

        #expect(page.total == 42)
        #expect(page.data.isEmpty)
    }
}
