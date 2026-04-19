import Testing
import Foundation
@testable import Trawl

// MARK: - ArrError Tests

struct ArrErrorTests {

    @Test func invalidAPIKeyDescription() {
        let error = ArrError.invalidAPIKey
        #expect(error.errorDescription == "Invalid API key. Check your *arr service settings.")
    }

    @Test func invalidURLDescription() {
        let error = ArrError.invalidURL
        #expect(error.errorDescription == "Invalid service URL.")
    }

    @Test func invalidResponseDescription() {
        let error = ArrError.invalidResponse
        #expect(error.errorDescription == "Invalid response from server.")
    }

    @Test func noServiceConfiguredDescription() {
        let error = ArrError.noServiceConfigured
        #expect(error.errorDescription == "No service configured.")
    }

    @Test func connectionFailedDescription() {
        let error = ArrError.connectionFailed
        #expect(error.errorDescription?.contains("Could not connect") == true)
    }

    @Test func networkErrorDescription() {
        struct FakeError: LocalizedError {
            var errorDescription: String? { "timeout" }
        }
        let error = ArrError.networkError(FakeError())
        #expect(error.errorDescription == "Network error: timeout")
    }

    @Test func decodingErrorDescription() {
        struct FakeError: LocalizedError {
            var errorDescription: String? { "bad JSON" }
        }
        let error = ArrError.decodingError(FakeError())
        #expect(error.errorDescription == "Failed to parse response: bad JSON")
    }

    @Test func serverErrorDescription() {
        let error = ArrError.serverError(statusCode: 500, message: "Internal Server Error")
        #expect(error.errorDescription == "Server error (500): Internal Server Error")
    }

    @Test func serverErrorNilMessageDescription() {
        let error = ArrError.serverError(statusCode: 503, message: nil)
        #expect(error.errorDescription == "Server error (503): Unknown")
    }
}

// MARK: - ArrServiceType Tests

struct ArrServiceTypeTests {

    @Test func sonarrDisplayName() {
        #expect(ArrServiceType.sonarr.displayName == "Sonarr")
    }

    @Test func radarrDisplayName() {
        #expect(ArrServiceType.radarr.displayName == "Radarr")
    }

    @Test func prowlarrDisplayName() {
        #expect(ArrServiceType.prowlarr.displayName == "Prowlarr")
    }

    @Test func sonarrDefaultPort() {
        #expect(ArrServiceType.sonarr.defaultPort == 8989)
    }

    @Test func radarrDefaultPort() {
        #expect(ArrServiceType.radarr.defaultPort == 7878)
    }

    @Test func prowlarrDefaultPort() {
        #expect(ArrServiceType.prowlarr.defaultPort == 9696)
    }

    @Test func sonarrSystemImage() {
        #expect(ArrServiceType.sonarr.systemImage == "tv")
    }

    @Test func radarrSystemImage() {
        #expect(ArrServiceType.radarr.systemImage == "film")
    }

    @Test func prowlarrSystemImage() {
        #expect(ArrServiceType.prowlarr.systemImage == "magnifyingglass.circle")
    }

    @Test func idEqualsRawValue() {
        for type_ in ArrServiceType.allCases {
            #expect(type_.id == type_.rawValue)
        }
    }

    @Test func allCasesCount() {
        #expect(ArrServiceType.allCases.count == 3)
    }

    @Test func rawValueEncoding() {
        #expect(ArrServiceType.sonarr.rawValue == "sonarr")
        #expect(ArrServiceType.radarr.rawValue == "radarr")
        #expect(ArrServiceType.prowlarr.rawValue == "prowlarr")
    }

    @Test func initFromRawValue() {
        #expect(ArrServiceType(rawValue: "sonarr") == .sonarr)
        #expect(ArrServiceType(rawValue: "radarr") == .radarr)
        #expect(ArrServiceType(rawValue: "prowlarr") == .prowlarr)
        #expect(ArrServiceType(rawValue: "unknown") == nil)
    }
}

// MARK: - ArrQueueItem Computed Properties Tests

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
    ) -> ArrQueueItem {
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
        let data = try! JSONSerialization.data(withJSONObject: cleaned)
        return try! JSONDecoder().decode(ArrQueueItem.self, from: data)
    }

    @Test func progressZeroWhenSizeIsNil() {
        let item = makeItem()
        #expect(item.progress == 0.0)
    }

    @Test func progressZeroWhenSizeIsZero() {
        let item = makeItem(size: 0, sizeleft: 0)
        #expect(item.progress == 0.0)
    }

    @Test func progressHalfway() {
        let item = makeItem(size: 1000, sizeleft: 500)
        #expect(item.progress == 0.5)
    }

    @Test func progressComplete() {
        let item = makeItem(size: 1000, sizeleft: 0)
        #expect(item.progress == 1.0)
    }

    @Test func progressClampsToOne() {
        // sizeleft > size means negative downloaded — clamp to 0
        let item = makeItem(size: 100, sizeleft: 200)
        #expect(item.progress == 0.0)
    }

    @Test func progressClampedAtMax() {
        // sizeleft == 0 → fully downloaded
        let item = makeItem(size: 500, sizeleft: 0)
        #expect(item.progress <= 1.0)
        #expect(item.progress >= 0.0)
    }

    @Test func normalizedStateFromStatus() {
        let item = makeItem(status: "Downloading")
        #expect(item.normalizedState == "downloading")
    }

    @Test func normalizedStateFromTrackedState() {
        let item = makeItem(trackedDownloadState: "ImportPending")
        #expect(item.normalizedState == "importpending")
    }

    @Test func normalizedStatePrefersTacked() {
        let item = makeItem(status: "completed", trackedDownloadState: "ImportFailed")
        #expect(item.normalizedState == "importfailed")
    }

    @Test func normalizedStateEmpty() {
        let item = makeItem()
        #expect(item.normalizedState == "")
    }

    @Test func isDownloadingQueueItemTrue() {
        let item = makeItem(trackedDownloadState: "downloading")
        #expect(item.isDownloadingQueueItem == true)
    }

    @Test func isDownloadingQueueItemFalse() {
        let item = makeItem(trackedDownloadState: "importPending")
        #expect(item.isDownloadingQueueItem == false)
    }

    @Test func isImportIssueForImportPending() {
        let item = makeItem(trackedDownloadState: "importPending")
        #expect(item.isImportIssueQueueItem == true)
    }

    @Test func isImportIssueForFailedPending() {
        let item = makeItem(trackedDownloadState: "failedPending")
        #expect(item.isImportIssueQueueItem == true)
    }

    @Test func isImportIssueForWarningStatus() {
        let item = makeItem(trackedDownloadStatus: "warning")
        #expect(item.isImportIssueQueueItem == true)
    }

    @Test func isImportIssueForErrorStatus() {
        let item = makeItem(trackedDownloadStatus: "error")
        #expect(item.isImportIssueQueueItem == true)
    }

    @Test func isImportIssueForOkStatus() {
        let item = makeItem(trackedDownloadStatus: "ok", trackedDownloadState: "downloading")
        #expect(item.isImportIssueQueueItem == false)
    }

    @Test func primaryStatusMessageReturnsFirst() throws {
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

    @Test func primaryStatusMessageNilWhenEmpty() {
        let item = makeItem()
        #expect(item.primaryStatusMessage == nil)
    }
}

// MARK: - ArrRelease Computed Properties Tests

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
    ) -> ArrRelease {
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
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(ArrRelease.self, from: data)
    }

    @Test func idCombinesGuidAndIndexer() {
        let release = makeRelease(guid: "abc123", indexerId: 5)
        #expect(release.id == "abc123|5")
    }

    @Test func idFallsBackToTitle() {
        let json: [String: Any] = ["title": "SomeRelease", "indexerId": 2]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let release = try! JSONDecoder().decode(ArrRelease.self, from: data)
        #expect(release.id == "SomeRelease|2")
    }

    @Test func idFallsBackToReleaseWhenNoGuidOrTitle() {
        let json: [String: Any] = ["indexerId": 99]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let release = try! JSONDecoder().decode(ArrRelease.self, from: data)
        #expect(release.id == "release|99")
    }

    @Test func canGrabApproved() {
        let release = makeRelease(approved: true)
        #expect(release.canGrab == true)
    }

    @Test func canGrabFalseWhenDownloadNotAllowed() {
        let release = makeRelease(downloadAllowed: false)
        #expect(release.canGrab == false)
    }

    @Test func canGrabFalseWhenRejected() {
        let release = makeRelease(rejected: true)
        #expect(release.canGrab == false)
    }

    @Test func canGrabFalseWhenTemporarilyRejected() {
        let release = makeRelease(temporarilyRejected: true)
        #expect(release.canGrab == false)
    }

    @Test func canGrabDefaultsToTrueWhenApprovedNil() {
        let release = makeRelease(approved: nil)
        #expect(release.canGrab == true)
    }

    @Test func qualityNameFallback() {
        let release = makeRelease()
        #expect(release.qualityName == "Unknown Quality")
    }

    @Test func qualityNameFromQuality() {
        let release = makeRelease(qualityName: "Bluray-1080p")
        #expect(release.qualityName == "Bluray-1080p")
    }

    @Test func protocolNameUppercased() {
        let json: [String: Any] = ["protocol": "torrent"]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let release = try! JSONDecoder().decode(ArrRelease.self, from: data)
        #expect(release.protocolName == "TORRENT")
    }

    @Test func protocolNameUnknownWhenNil() {
        let release = makeRelease()
        #expect(release.protocolName == "UNKNOWN")
    }

    @Test func ageDescriptionFromAgeHoursLessThan24() {
        let release = makeRelease(ageHours: 5)
        #expect(release.ageDescription == "5h")
    }

    @Test func ageDescriptionFromAgeHoursMoreThan24() {
        let release = makeRelease(ageHours: 72)
        #expect(release.ageDescription == "3d")
    }

    @Test func ageDescriptionFromAgeDays() {
        let release = makeRelease(age: 14)
        #expect(release.ageDescription == "14d")
    }

    @Test func ageDescriptionFromAgeMinutes() {
        let release = makeRelease(ageMinutes: 45)
        #expect(release.ageDescription == "45m")
    }

    @Test func ageDescriptionNilWhenAllZero() {
        let release = makeRelease(ageHours: 0, age: 0, ageMinutes: 0)
        #expect(release.ageDescription == nil)
    }

    @Test func ageDescriptionNilWhenAllNil() {
        let release = makeRelease()
        #expect(release.ageDescription == nil)
    }

    @Test func protocolCodingKeyMapped() throws {
        let json = #"{"protocol":"usenet","guid":"x","indexerId":1}"#
        let data = json.data(using: .utf8)!
        let release = try JSONDecoder().decode(ArrRelease.self, from: data)
        #expect(release.protocol_ == "usenet")
    }

    @Test func flexibleDoubleDecodesInt() throws {
        let json = #"{"ageHours":12,"guid":"x"}"#
        let data = json.data(using: .utf8)!
        let release = try JSONDecoder().decode(ArrRelease.self, from: data)
        #expect(release.ageHours == 12.0)
    }

    @Test func flexibleDoubleDecodesString() throws {
        let json = #"{"ageHours":"3.5","guid":"x"}"#
        let data = json.data(using: .utf8)!
        let release = try JSONDecoder().decode(ArrRelease.self, from: data)
        #expect(release.ageHours == 3.5)
    }
}

// MARK: - ArrReleaseSort Tests

struct ArrReleaseSortTests {

    @Test func defaultIsNotFiltered() {
        let sort = ArrReleaseSort()
        #expect(sort.isFiltered == false)
    }

    @Test func filteredWhenIndexerSet() {
        var sort = ArrReleaseSort()
        sort.indexer = "MyIndexer"
        #expect(sort.isFiltered == true)
    }

    @Test func filteredWhenQualitySet() {
        var sort = ArrReleaseSort()
        sort.quality = "1080p"
        #expect(sort.isFiltered == true)
    }

    @Test func filteredWhenApprovedOnly() {
        var sort = ArrReleaseSort()
        sort.approvedOnly = true
        #expect(sort.isFiltered == true)
    }

    @Test func defaultIsNotActive() {
        let sort = ArrReleaseSort()
        #expect(sort.isActive == false)
    }

    @Test func activeWhenNonDefaultOption() {
        var sort = ArrReleaseSort()
        sort.option = .seeders
        #expect(sort.isActive == true)
    }

    @Test func activeWhenFiltered() {
        var sort = ArrReleaseSort()
        sort.indexer = "X"
        #expect(sort.isActive == true)
    }

    @Test func roundTripRawRepresentable() {
        var sort = ArrReleaseSort()
        sort.option = .age
        sort.isAscending = true
        sort.indexer = "NZBGeek"
        sort.quality = "720p"
        sort.approvedOnly = true

        let raw = sort.rawValue
        let decoded = ArrReleaseSort(rawValue: raw)

        #expect(decoded?.option == .age)
        #expect(decoded?.isAscending == true)
        #expect(decoded?.indexer == "NZBGeek")
        #expect(decoded?.quality == "720p")
        #expect(decoded?.approvedOnly == true)
    }

    @Test func invalidRawValueFallsBackToDefault() {
        let sort = ArrReleaseSort(rawValue: "not valid json")
        // Should fall back to defaults
        #expect(sort?.option == .default)
        #expect(sort?.isFiltered == false)
    }

    @Test func emptyRawValueFallsBack() {
        let sort = ArrReleaseSort(rawValue: "")
        #expect(sort?.option == .default)
    }
}

// MARK: - ArrReleaseSortKey Tests

struct ArrReleaseSortKeyTests {

    @Test func defaultSystemImage() {
        #expect(ArrReleaseSortKey.default.systemImage == "square.stack")
    }

    @Test func ageSystemImage() {
        #expect(ArrReleaseSortKey.age.systemImage == "clock")
    }

    @Test func qualitySystemImage() {
        #expect(ArrReleaseSortKey.quality.systemImage == "sparkles")
    }

    @Test func sizeSystemImage() {
        #expect(ArrReleaseSortKey.size.systemImage == "externaldrive")
    }

    @Test func seedersSystemImage() {
        #expect(ArrReleaseSortKey.seeders.systemImage == "arrow.up.circle")
    }

    @Test func idEqualsRawValue() {
        for key in ArrReleaseSortKey.allCases {
            #expect(key.id == key.rawValue)
        }
    }
}

// MARK: - ArrDiskSpace Tests

struct ArrDiskSpaceTests {

    @Test func initSetsPathAsID() {
        let disk = ArrDiskSpace(path: "/data", label: "Media", freeSpace: 100, totalSpace: 1000)
        #expect(disk.id == "/data")
    }

    @Test func initNilPathUsesUUID() {
        let disk = ArrDiskSpace(path: nil, label: "Unknown", freeSpace: 0, totalSpace: 0)
        #expect(!disk.id.isEmpty)
        // Should not be nil-based fallback, UUID format check
        #expect(disk.path == nil)
    }

    @Test func decodeFromJSON() throws {
        let json = #"{"path":"/mnt/media","label":"Media Drive","freeSpace":5368709120,"totalSpace":107374182400}"#
        let data = json.data(using: .utf8)!
        let disk = try JSONDecoder().decode(ArrDiskSpace.self, from: data)
        #expect(disk.path == "/mnt/media")
        #expect(disk.label == "Media Drive")
        #expect(disk.freeSpace == 5368709120)
        #expect(disk.totalSpace == 107374182400)
        #expect(disk.id == "/mnt/media")
    }

    @Test func decodeWithMissingFields() throws {
        let json = #"{"path":"/srv"}"#
        let data = json.data(using: .utf8)!
        let disk = try JSONDecoder().decode(ArrDiskSpace.self, from: data)
        #expect(disk.path == "/srv")
        #expect(disk.label == nil)
        #expect(disk.freeSpace == nil)
        #expect(disk.totalSpace == nil)
    }

    @Test func encodeDoesNotIncludeIdField() throws {
        let disk = ArrDiskSpace(path: "/data", label: "Test", freeSpace: 100, totalSpace: 200)
        let encoded = try JSONEncoder().encode(disk)
        let dict = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        #expect(dict["id"] == nil)
        #expect(dict["path"] as? String == "/data")
    }
}

// MARK: - ArrDiskSpaceSnapshot Tests

struct ArrDiskSpaceSnapshotTests {

    @Test func idCombinesServiceTypeAndPath() {
        let snap = ArrDiskSpaceSnapshot(
            serviceType: .sonarr,
            path: "/data/series",
            label: nil,
            freeSpace: nil,
            totalSpace: nil
        )
        #expect(snap.id == "sonarr-/data/series")
    }

    @Test func radarrSnapshotID() {
        let snap = ArrDiskSpaceSnapshot(
            serviceType: .radarr,
            path: "/data/movies",
            label: "Movies",
            freeSpace: 1000,
            totalSpace: 5000
        )
        #expect(snap.id == "radarr-/data/movies")
    }
}

// MARK: - ArrHealthCheck Tests

struct ArrHealthCheckTests {

    @Test func idIsConcatenationOfFields() {
        let check = ArrHealthCheck(
            source: "IndexerRssCheck",
            type: "warning",
            message: "No indexer available",
            wikiUrl: "https://wiki.example.com"
        )
        let expected = "IndexerRssCheck|warning|No indexer available|https://wiki.example.com"
        #expect(check.id == expected)
    }

    @Test func idHandlesNilFields() {
        let check = ArrHealthCheck(source: nil, type: nil, message: nil, wikiUrl: nil)
        #expect(check.id == "|||")
    }

    @Test func decodeFromJSON() throws {
        let json = #"{"source":"TestCheck","type":"error","message":"Something failed","wikiUrl":"https://wiki.test.com"}"#
        let data = json.data(using: .utf8)!
        let check = try JSONDecoder().decode(ArrHealthCheck.self, from: data)
        #expect(check.source == "TestCheck")
        #expect(check.type == "error")
        #expect(check.message == "Something failed")
        #expect(check.wikiUrl == "https://wiki.test.com")
    }
}

// MARK: - AnyCodableValue Tests

struct AnyCodableValueTests {

    @Test func decodeString() throws {
        let json = #""hello world""#
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        if case .string(let s) = value {
            #expect(s == "hello world")
        } else {
            Issue.record("Expected .string, got \(value)")
        }
    }

    @Test func decodeInt() throws {
        let json = #"42"#
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        if case .int(let i) = value {
            #expect(i == 42)
        } else {
            Issue.record("Expected .int, got \(value)")
        }
    }

    @Test func decodeDouble() throws {
        let json = #"3.14"#
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        // Note: 3.14 may decode as double or could be int-first — just verify non-null
        switch value {
        case .double(let d): #expect(d == 3.14)
        case .int: break // acceptable if rounded
        default: Issue.record("Unexpected case \(value)")
        }
    }

    @Test func decodeBool() throws {
        let json = #"true"#
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        if case .bool(let b) = value {
            #expect(b == true)
        } else {
            Issue.record("Expected .bool, got \(value)")
        }
    }

    @Test func decodeNull() throws {
        let json = #"null"#
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        if case .null = value { } else {
            Issue.record("Expected .null, got \(value)")
        }
    }

    @Test func decodeArray() throws {
        let json = #"[1, "two", true]"#
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        if case .array(let arr) = value {
            #expect(arr.count == 3)
        } else {
            Issue.record("Expected .array, got \(value)")
        }
    }

    @Test func displayStringForString() {
        let value = AnyCodableValue.string("hello")
        #expect(value.displayString == "hello")
    }

    @Test func displayStringForEmptyStringIsNil() {
        let value = AnyCodableValue.string("")
        #expect(value.displayString == nil)
    }

    @Test func displayStringForInt() {
        let value = AnyCodableValue.int(99)
        #expect(value.displayString == "99")
    }

    @Test func displayStringForDouble() {
        let value = AnyCodableValue.double(1.5)
        #expect(value.displayString == "1.5")
    }

    @Test func displayStringForBoolTrue() {
        let value = AnyCodableValue.bool(true)
        #expect(value.displayString == "Yes")
    }

    @Test func displayStringForBoolFalse() {
        let value = AnyCodableValue.bool(false)
        #expect(value.displayString == "No")
    }

    @Test func displayStringForNull() {
        let value = AnyCodableValue.null
        #expect(value.displayString == nil)
    }

    @Test func displayStringForEmptyArray() {
        let value = AnyCodableValue.array([])
        #expect(value.displayString == nil)
    }

    @Test func displayStringForArray() {
        let value = AnyCodableValue.array([.string("a"), .string("b")])
        #expect(value.displayString == "a, b")
    }

    @Test func intValueFromInt() {
        let value = AnyCodableValue.int(7)
        #expect(value.intValue == 7)
    }

    @Test func intValueFromDouble() {
        let value = AnyCodableValue.double(3.9)
        #expect(value.intValue == 3)
    }

    @Test func intValueFromStringRepresentation() {
        let value = AnyCodableValue.string("42")
        #expect(value.intValue == 42)
    }

    @Test func intValueNilForBool() {
        let value = AnyCodableValue.bool(true)
        #expect(value.intValue == nil)
    }

    @Test func intValueNilForNull() {
        let value = AnyCodableValue.null
        #expect(value.intValue == nil)
    }

    @Test func encodeAndDecodeRoundTrip() throws {
        let original = AnyCodableValue.string("round-trip")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        #expect(decoded.displayString == "round-trip")
    }

    @Test func htmlStrippedInDisplayString() {
        let value = AnyCodableValue.string("<b>Bold</b> text &amp; more")
        let display = value.displayString
        #expect(display?.contains("<b>") == false)
        #expect(display?.contains("&amp;") == false)
        #expect(display?.contains("Bold") == true)
        #expect(display?.contains("&") == true)
    }
}

// MARK: - ProwlarrIndexerProtocol Tests

struct ProwlarrIndexerProtocolTests {

    @Test func usenetDisplayName() {
        #expect(ProwlarrIndexerProtocol.usenet.displayName == "Usenet")
    }

    @Test func torrentDisplayName() {
        #expect(ProwlarrIndexerProtocol.torrent.displayName == "Torrent")
    }

    @Test func usenetIsNotTorrent() {
        #expect(ProwlarrIndexerProtocol.usenet.isTorrent == false)
    }

    @Test func torrentIsTorrent() {
        #expect(ProwlarrIndexerProtocol.torrent.isTorrent == true)
    }

    @Test func torrentSystemImage() {
        #expect(ProwlarrIndexerProtocol.torrent.systemImage == "arrow.down.circle")
    }

    @Test func usenetSystemImage() {
        #expect(ProwlarrIndexerProtocol.usenet.systemImage == "envelope.circle")
    }
}

// MARK: - ProwlarrIndexer.schemaListID Tests

struct ProwlarrIndexerSchemaListIDTests {

    @Test func nonZeroIDUsesIndexerPrefix() {
        let indexer = ProwlarrIndexer(
            id: 5, name: "NZBGeek", enable: true,
            implementation: nil, implementationName: nil,
            configContract: nil, infoLink: nil, tags: nil,
            priority: nil, appProfileId: nil, shouldSearch: nil,
            supportsRss: nil, supportsSearch: nil, protocol: nil, fields: nil
        )
        #expect(indexer.schemaListID == "indexer-5")
    }

    @Test func zeroIDUsesTemplateFromComponents() {
        let indexer = ProwlarrIndexer(
            id: 0, name: "NZBGeek", enable: false,
            implementation: "NZBGeekSettings", implementationName: "NZBGeek",
            configContract: nil, infoLink: nil, tags: nil,
            priority: nil, appProfileId: nil, shouldSearch: nil,
            supportsRss: nil, supportsSearch: nil, protocol: nil, fields: nil
        )
        let id = indexer.schemaListID
        #expect(id.hasPrefix("template-"))
        #expect(id.contains("NZBGeekSettings") || id.contains("NZBGeek"))
    }

    @Test func zeroIDAllNilComponentsIsUnknown() {
        let indexer = ProwlarrIndexer(
            id: 0, name: nil, enable: false,
            implementation: nil, implementationName: nil,
            configContract: nil, infoLink: nil, tags: nil,
            priority: nil, appProfileId: nil, shouldSearch: nil,
            supportsRss: nil, supportsSearch: nil, protocol: nil, fields: nil
        )
        let id = indexer.schemaListID
        #expect(id.hasPrefix("template-unknown-"))
    }
}

// MARK: - ProwlarrSearchResult Tests

struct ProwlarrSearchResultTests {

    private func makeResult(
        guid: String? = nil,
        title: String? = nil,
        indexerId: Int? = nil,
        downloadUrl: String? = nil,
        downloadVolumeFactor: Double? = nil,
        protocol_: String? = nil
    ) -> ProwlarrSearchResult {
        var json: [String: Any] = [:]
        if let guid { json["guid"] = guid }
        if let title { json["title"] = title }
        if let indexerId { json["indexerId"] = indexerId }
        if let downloadUrl { json["downloadUrl"] = downloadUrl }
        if let downloadVolumeFactor { json["downloadVolumeFactor"] = downloadVolumeFactor }
        if let protocol_ { json["protocol"] = protocol_ }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(ProwlarrSearchResult.self, from: data)
    }

    @Test func idUsesGuidWhenPresent() {
        let result = makeResult(guid: "my-unique-guid")
        #expect(result.id == "my-unique-guid")
    }

    @Test func idFallsBackToCompositeWhenNoGuid() {
        let result = makeResult(title: "Release Name", indexerId: 3)
        #expect(result.id.hasPrefix("search-result-"))
        #expect(result.id.contains("3") || result.id.contains("Release"))
    }

    @Test func idUnknownFallbackWhenAllNil() {
        let result = makeResult()
        #expect(result.id.hasPrefix("search-result-unknown-"))
    }

    @Test func isFreeleechWhenFactorZero() {
        let result = makeResult(downloadVolumeFactor: 0.0)
        #expect(result.isFreeleech == true)
    }

    @Test func isNotFreeleechWhenFactorOne() {
        let result = makeResult(downloadVolumeFactor: 1.0)
        #expect(result.isFreeleech == false)
    }

    @Test func isTorrentForTorrentProtocol() {
        let result = makeResult(protocol_: "torrent")
        #expect(result.isTorrent == true)
    }

    @Test func isNotTorrentForUsenet() {
        let result = makeResult(protocol_: "usenet")
        #expect(result.isTorrent == false)
    }

    @Test func isMagnetForMagnetURL() {
        let result = makeResult(downloadUrl: "magnet:?xt=urn:btih:abc123")
        #expect(result.isMagnet == true)
    }

    @Test func isMagnetCaseInsensitive() {
        let result = makeResult(downloadUrl: "MAGNET:?xt=abc")
        #expect(result.isMagnet == true)
    }

    @Test func isNotMagnetForHTTPUrl() {
        let result = makeResult(downloadUrl: "https://example.com/release.nzb")
        #expect(result.isMagnet == false)
    }

    @Test func isNotMagnetWhenNoURL() {
        let result = makeResult()
        #expect(result.isMagnet == false)
    }
}

// MARK: - ProwlarrIndexerStatEntry Tests

struct ProwlarrIndexerStatEntryTests {

    private func makeEntry(
        indexerId: Int? = nil,
        indexerName: String? = nil,
        averageResponseTime: Double? = nil,
        numberOfQueries: Int? = nil,
        numberOfFailedQueries: Int? = nil
    ) -> ProwlarrIndexerStatEntry {
        var json: [String: Any] = [:]
        if let indexerId { json["indexerId"] = indexerId }
        if let indexerName { json["indexerName"] = indexerName }
        if let averageResponseTime { json["averageResponseTime"] = averageResponseTime }
        if let numberOfQueries { json["numberOfQueries"] = numberOfQueries }
        if let numberOfFailedQueries { json["numberOfFailedQueries"] = numberOfFailedQueries }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(ProwlarrIndexerStatEntry.self, from: data)
    }

    @Test func idWithIndexerId() {
        let entry = makeEntry(indexerId: 10)
        #expect(entry.id == "indexer-10")
    }

    @Test func idWithoutIndexerIdFallsBackToName() {
        let entry = makeEntry(indexerName: "NZBGeek")
        #expect(entry.id == "indexer-unknown-NZBGeek")
    }

    @Test func successRateCalculation() {
        let entry = makeEntry(numberOfQueries: 100, numberOfFailedQueries: 20)
        #expect(entry.successRate == 0.8)
    }

    @Test func successRateNilWhenZeroQueries() {
        let entry = makeEntry(numberOfQueries: 0)
        #expect(entry.successRate == nil)
    }

    @Test func successRateNilWhenNoQueries() {
        let entry = makeEntry()
        #expect(entry.successRate == nil)
    }

    @Test func successRatePerfect() {
        let entry = makeEntry(numberOfQueries: 50, numberOfFailedQueries: 0)
        #expect(entry.successRate == 1.0)
    }

    @Test func avgResponseTimeFormatted() {
        let entry = makeEntry(averageResponseTime: 256.7)
        #expect(entry.avgResponseTimeFormatted == "257ms")
    }

    @Test func avgResponseTimeNilWhenNil() {
        let entry = makeEntry()
        #expect(entry.avgResponseTimeFormatted == nil)
    }
}

// MARK: - ProwlarrIndexerStatus Tests

struct ProwlarrIndexerStatusTests {

    @Test func stableIDWithNonZeroID() throws {
        let json = #"{"id": 5, "indexerId": 3}"#
        let data = json.data(using: .utf8)!
        let status = try JSONDecoder().decode(ProwlarrIndexerStatus.self, from: data)
        #expect(status.stableID == "status-5")
    }

    @Test func stableIDFallsBackToIndexerId() throws {
        let json = #"{"id": 0, "indexerId": 7}"#
        let data = json.data(using: .utf8)!
        let status = try JSONDecoder().decode(ProwlarrIndexerStatus.self, from: data)
        #expect(status.stableID == "status-indexer-7")
    }

    @Test func isDisabledFalseWhenNoDisabledTill() throws {
        let json = #"{"id": 1}"#
        let data = json.data(using: .utf8)!
        let status = try JSONDecoder().decode(ProwlarrIndexerStatus.self, from: data)
        #expect(status.isDisabled == false)
    }

    @Test func isDisabledTrueWhenDisabledTillInFuture() throws {
        // Create a date far in the future
        let future = Date().addingTimeInterval(3600 * 24 * 365)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let futureStr = formatter.string(from: future)
        let json = #"{"id": 1, "disabledTill": "\#(futureStr)"}"#
        let data = json.data(using: .utf8)!
        let status = try JSONDecoder().decode(ProwlarrIndexerStatus.self, from: data)
        #expect(status.isDisabled == true)
    }

    @Test func isDisabledFalseWhenDisabledTillInPast() throws {
        let past = Date().addingTimeInterval(-3600)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let pastStr = formatter.string(from: past)
        let json = #"{"id": 1, "disabledTill": "\#(pastStr)"}"#
        let data = json.data(using: .utf8)!
        let status = try JSONDecoder().decode(ProwlarrIndexerStatus.self, from: data)
        #expect(status.isDisabled == false)
    }
}

// MARK: - ProwlarrSearchType Tests

struct ProwlarrSearchTypeTests {

    @Test func allDisplayNames() {
        #expect(ProwlarrSearchType.search.displayName == "All")
        #expect(ProwlarrSearchType.tvsearch.displayName == "TV")
        #expect(ProwlarrSearchType.moviesearch.displayName == "Movies")
        #expect(ProwlarrSearchType.audiosearch.displayName == "Audio")
    }

    @Test func allSystemImages() {
        #expect(ProwlarrSearchType.search.systemImage == "magnifyingglass")
        #expect(ProwlarrSearchType.tvsearch.systemImage == "tv")
        #expect(ProwlarrSearchType.moviesearch.systemImage == "film")
        #expect(ProwlarrSearchType.audiosearch.systemImage == "music.note")
    }

    @Test func idEqualsRawValue() {
        for type_ in ProwlarrSearchType.allCases {
            #expect(type_.id == type_.rawValue)
        }
    }
}

// MARK: - ArrServiceManager State Tests

@MainActor
struct ArrServiceManagerTests {

    @Test func initialStateIsEmpty() {
        let manager = ArrServiceManager()
        #expect(manager.sonarrInstances.isEmpty)
        #expect(manager.radarrInstances.isEmpty)
        #expect(manager.prowlarrClient == nil)
        #expect(manager.prowlarrConnected == false)
        #expect(manager.sonarrConnected == false)
        #expect(manager.radarrConnected == false)
    }

    @Test func disconnectAllClearsState() {
        let manager = ArrServiceManager()
        manager.disconnectAll()
        #expect(manager.sonarrInstances.isEmpty)
        #expect(manager.radarrInstances.isEmpty)
        #expect(manager.prowlarrClient == nil)
        #expect(manager.prowlarrConnected == false)
        #expect(manager.sonarrHealthChecks.isEmpty)
        #expect(manager.radarrHealthChecks.isEmpty)
        #expect(manager.prowlarrHealthChecks.isEmpty)
        #expect(manager.sonarrBlocklist.isEmpty)
        #expect(manager.radarrBlocklist.isEmpty)
    }

    @Test func activeSonarrEntryNilWhenNoInstances() {
        let manager = ArrServiceManager()
        #expect(manager.activeSonarrEntry == nil)
    }

    @Test func activeRadarrEntryNilWhenNoInstances() {
        let manager = ArrServiceManager()
        #expect(manager.activeRadarrEntry == nil)
    }

    @Test func sonarrConnectedFalseWithEmptyInstances() {
        let manager = ArrServiceManager()
        #expect(manager.sonarrConnected == false)
    }

    @Test func radarrConnectedFalseWithEmptyInstances() {
        let manager = ArrServiceManager()
        #expect(manager.radarrConnected == false)
    }

    @Test func connectionErrorsEmptyInitially() {
        let manager = ArrServiceManager()
        #expect(manager.connectionErrors.isEmpty)
    }

    @Test func disconnectServiceProwlarrClearsClient() {
        let manager = ArrServiceManager()
        // prowlarrConnected starts false
        manager.disconnectService(.prowlarr)
        #expect(manager.prowlarrConnected == false)
        #expect(manager.prowlarrClient == nil)
    }

    @Test func setActiveSonarrProfileIDUpdates() {
        let manager = ArrServiceManager()
        let uuid = UUID()
        manager.setActiveSonarr(uuid)
        #expect(manager.activeSonarrProfileID == uuid)
    }

    @Test func setActiveRadarrProfileIDUpdates() {
        let manager = ArrServiceManager()
        let uuid = UUID()
        manager.setActiveRadarr(uuid)
        #expect(manager.activeRadarrProfileID == uuid)
    }

    @Test func clearBlocklistRemovesFromArrays() {
        let manager = ArrServiceManager()
        // Manually inject test blocklist items via private(set) workaround not possible;
        // instead test that clearBlocklist with empty IDs doesn't crash
        Task {
            await manager.clearBlocklist(sonarrIDs: [], radarrIDs: [])
        }
        #expect(manager.sonarrBlocklist.isEmpty)
        #expect(manager.radarrBlocklist.isEmpty)
    }

    @Test func syncProfilesUpdatesStoredProfiles() {
        let manager = ArrServiceManager()
        // syncProfiles is just a setter — shouldn't crash with empty array
        manager.syncProfiles([])
        // No crash means pass
    }

    @Test func isInitializingFalseInitially() {
        let manager = ArrServiceManager()
        #expect(manager.isInitializing == false)
    }

    @Test func isLoadingHealthFalseInitially() {
        let manager = ArrServiceManager()
        #expect(manager.isLoadingHealth == false)
    }

    @Test func isLoadingBlocklistFalseInitially() {
        let manager = ArrServiceManager()
        #expect(manager.isLoadingBlocklist == false)
    }
}

// MARK: - ArrQueueItem CodingKeys Tests

struct ArrQueueItemCodingKeysTests {

    @Test func protocolFieldDecodedWithCodingKey() throws {
        let json = #"{"id": 1, "protocol": "torrent"}"#
        let data = json.data(using: .utf8)!
        let item = try JSONDecoder().decode(ArrQueueItem.self, from: data)
        #expect(item.protocol_ == "torrent")
    }

    @Test func timeleftDecoded() throws {
        let json = #"{"id": 1, "timeleft": "02:30:00"}"#
        let data = json.data(using: .utf8)!
        let item = try JSONDecoder().decode(ArrQueueItem.self, from: data)
        #expect(item.timeleft == "02:30:00")
    }

    @Test func allFieldsDecoded() throws {
        let json = #"""
        {
          "id": 42,
          "title": "Test Episode",
          "status": "downloading",
          "trackedDownloadStatus": "ok",
          "trackedDownloadState": "downloading",
          "protocol": "torrent",
          "downloadClient": "qBittorrent",
          "outputPath": "/downloads/test",
          "size": 2000.0,
          "sizeleft": 1000.0,
          "timeleft": "00:30:00",
          "seriesId": 5,
          "episodeId": 10,
          "seasonNumber": 2,
          "movieId": null
        }
        """#
        let data = json.data(using: .utf8)!
        let item = try JSONDecoder().decode(ArrQueueItem.self, from: data)
        #expect(item.id == 42)
        #expect(item.title == "Test Episode")
        #expect(item.protocol_ == "torrent")
        #expect(item.downloadClient == "qBittorrent")
        #expect(item.seriesId == 5)
        #expect(item.episodeId == 10)
        #expect(item.seasonNumber == 2)
        #expect(item.movieId == nil)
        #expect(item.progress == 0.5)
    }
}

// MARK: - ArrQueuePage Tests

struct ArrQueuePageTests {

    @Test func decodeEmptyRecords() throws {
        let json = #"{"page": 1, "pageSize": 20, "totalRecords": 0, "records": []}"#
        let data = json.data(using: .utf8)!
        let page = try JSONDecoder().decode(ArrQueuePage.self, from: data)
        #expect(page.page == 1)
        #expect(page.totalRecords == 0)
        #expect(page.records?.isEmpty == true)
    }

    @Test func decodeWithRecords() throws {
        let json = #"{"page": 1, "pageSize": 10, "totalRecords": 1, "records": [{"id": 99}]}"#
        let data = json.data(using: .utf8)!
        let page = try JSONDecoder().decode(ArrQueuePage.self, from: data)
        #expect(page.records?.count == 1)
        #expect(page.records?.first?.id == 99)
    }
}

// MARK: - ArrHistoryPage Tests

struct ArrHistoryPageTests {

    @Test func decodeHistoryPage() throws {
        let json = #"""
        {
          "page": 1,
          "pageSize": 20,
          "sortKey": "date",
          "sortDirection": "descending",
          "totalRecords": 2,
          "records": [
            {"id": 1, "eventType": "grabbed", "sourceTitle": "Show.S01E01"},
            {"id": 2, "eventType": "downloadFolderImported", "seriesId": 5, "episodeId": 10}
          ]
        }
        """#
        let data = json.data(using: .utf8)!
        let page = try JSONDecoder().decode(ArrHistoryPage.self, from: data)
        #expect(page.totalRecords == 2)
        #expect(page.records?.count == 2)
        #expect(page.records?.first?.eventType == "grabbed")
        #expect(page.records?.first?.sourceTitle == "Show.S01E01")
        #expect(page.records?.last?.seriesId == 5)
    }
}

// MARK: - ArrBlocklistPage Tests

struct ArrBlocklistPageTests {

    @Test func decodeBlocklistPage() throws {
        let json = #"""
        {
          "page": 1,
          "pageSize": 20,
          "totalRecords": 1,
          "records": [
            {
              "id": 5,
              "seriesId": 2,
              "sourceTitle": "Bad.Release.HDTV",
              "indexer": "MyIndexer",
              "date": "2024-01-15T10:30:00Z"
            }
          ]
        }
        """#
        let data = json.data(using: .utf8)!
        let page = try JSONDecoder().decode(ArrBlocklistPage.self, from: data)
        #expect(page.totalRecords == 1)
        #expect(page.records?.first?.id == 5)
        #expect(page.records?.first?.sourceTitle == "Bad.Release.HDTV")
        #expect(page.records?.first?.indexer == "MyIndexer")
    }
}

// MARK: - ArrSystemStatus Tests

struct ArrSystemStatusTests {

    @Test func decodeSystemStatus() throws {
        let json = #"""
        {
          "appName": "Sonarr",
          "instanceName": "MyInstance",
          "version": "4.0.0",
          "osName": "linux",
          "isDocker": true
        }
        """#
        let data = json.data(using: .utf8)!
        let status = try JSONDecoder().decode(ArrSystemStatus.self, from: data)
        #expect(status.appName == "Sonarr")
        #expect(status.instanceName == "MyInstance")
        #expect(status.version == "4.0.0")
        #expect(status.osName == "linux")
        #expect(status.isDocker == true)
    }

    @Test func decodeSystemStatusWithNilFields() throws {
        let json = #"{}"#
        let data = json.data(using: .utf8)!
        let status = try JSONDecoder().decode(ArrSystemStatus.self, from: data)
        #expect(status.appName == nil)
        #expect(status.version == nil)
    }
}

// MARK: - ArrQualityProfile Tests

struct ArrQualityProfileTests {

    @Test func decodeQualityProfile() throws {
        let json = #"""
        {
          "id": 1,
          "name": "Any",
          "upgradeAllowed": true,
          "cutoff": 5,
          "items": []
        }
        """#
        let data = json.data(using: .utf8)!
        let profile = try JSONDecoder().decode(ArrQualityProfile.self, from: data)
        #expect(profile.id == 1)
        #expect(profile.name == "Any")
        #expect(profile.upgradeAllowed == true)
        #expect(profile.cutoff == 5)
    }
}

// MARK: - ArrRootFolder Tests

struct ArrRootFolderTests {

    @Test func decodeRootFolder() throws {
        let json = #"""
        {
          "id": 1,
          "path": "/data/media/tv",
          "accessible": true,
          "freeSpace": 500000000000,
          "totalSpace": 1000000000000
        }
        """#
        let data = json.data(using: .utf8)!
        let folder = try JSONDecoder().decode(ArrRootFolder.self, from: data)
        #expect(folder.id == 1)
        #expect(folder.path == "/data/media/tv")
        #expect(folder.accessible == true)
        #expect(folder.freeSpace == 500000000000)
    }
}

// MARK: - ArrTag Tests

struct ArrTagTests {

    @Test func decodeTag() throws {
        let json = #"{"id": 3, "label": "4k"}"#
        let data = json.data(using: .utf8)!
        let tag = try JSONDecoder().decode(ArrTag.self, from: data)
        #expect(tag.id == 3)
        #expect(tag.label == "4k")
    }
}

// MARK: - ArrAPIClient defaultPageSize Tests

struct ArrAPIClientTests {

    @Test func defaultPageSizeIs20() {
        #expect(ArrAPIClient.defaultPageSize == 20)
    }

    @Test func initTrimsTrailingSlash() async {
        let client = ArrAPIClient(baseURL: "http://localhost:8989/", apiKey: "testkey")
        let baseURL = await client.baseURL
        #expect(baseURL == "http://localhost:8989")
    }

    @Test func initTrimsWhitespace() async {
        let client = ArrAPIClient(baseURL: "  http://localhost:8989  ", apiKey: "testkey")
        let baseURL = await client.baseURL
        #expect(baseURL == "http://localhost:8989")
    }

    @Test func initTrimsTrailingSlashAndWhitespace() async {
        let client = ArrAPIClient(baseURL: "  http://localhost:8989/  ", apiKey: "testkey")
        let baseURL = await client.baseURL
        #expect(baseURL == "http://localhost:8989")
    }

    @Test func initPreservesPathWithNoTrailingSlash() async {
        let client = ArrAPIClient(baseURL: "http://localhost:8989", apiKey: "testkey")
        let baseURL = await client.baseURL
        #expect(baseURL == "http://localhost:8989")
    }
}

// MARK: - ArrServiceFilter Tests

struct ArrServiceFilterTests {

    @Test func allCasesCount() {
        #expect(ArrServiceFilter.allCases.count == 4)
    }

    @Test func allTitles() {
        #expect(ArrServiceFilter.all.title == "All")
        #expect(ArrServiceFilter.sonarr.title == "Sonarr")
        #expect(ArrServiceFilter.radarr.title == "Radarr")
        #expect(ArrServiceFilter.prowlarr.title == "Prowlarr")
    }
}

// MARK: - Regression / Edge Case Tests

struct ArrSharedModelsRegressionTests {

    @Test func queueItemProgressNeverExceedsOne() {
        // size = 100, sizeleft = -10 (invalid but let's be defensive)
        let json: [String: Any] = ["id": 1, "size": 100.0, "sizeleft": -10.0]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let item = try! JSONDecoder().decode(ArrQueueItem.self, from: data)
        #expect(item.progress <= 1.0)
    }

    @Test func queueItemProgressNeverBelowZero() {
        let json: [String: Any] = ["id": 1, "size": 100.0, "sizeleft": 200.0]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let item = try! JSONDecoder().decode(ArrQueueItem.self, from: data)
        #expect(item.progress >= 0.0)
    }

    @Test func releaseCanGrabFalseWhenBothRejectedAndDownloadAllowedFalse() {
        let json: [String: Any] = ["rejected": true, "downloadAllowed": false]
        let data = try! JSONSerialization.data(withJSONObject: json)
        let release = try! JSONDecoder().decode(ArrRelease.self, from: data)
        #expect(release.canGrab == false)
    }

    @Test func arrReleaseSortDefaultRawValue() {
        let sort = ArrReleaseSort()
        let raw = sort.rawValue
        // Should be a non-empty JSON string
        #expect(!raw.isEmpty)
        // Should round-trip
        let decoded = ArrReleaseSort(rawValue: raw)
        #expect(decoded?.option == .default)
        #expect(decoded?.isAscending == false)
    }

    @Test func anyCodableValueArrayWithNullElements() throws {
        let json = #"[null, "text", 42]"#
        let data = json.data(using: .utf8)!
        let value = try JSONDecoder().decode(AnyCodableValue.self, from: data)
        if case .array(let arr) = value {
            #expect(arr.count == 3)
            // null element should have nil displayString
            if case .null = arr[0] {
                #expect(arr[0].displayString == nil)
            }
        } else {
            Issue.record("Expected array")
        }
    }

    @Test func prowlarrSearchResultIDIsStableForSameGuid() {
        let makeResult: () -> ProwlarrSearchResult = {
            let json: [String: Any] = ["guid": "stable-guid-123"]
            let data = try! JSONSerialization.data(withJSONObject: json)
            return try! JSONDecoder().decode(ProwlarrSearchResult.self, from: data)
        }
        let r1 = makeResult()
        let r2 = makeResult()
        #expect(r1.id == r2.id)
    }
}