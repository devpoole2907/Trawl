import Testing
import Foundation
@testable import Trawl

// MARK: - JellyfinAPIError Tests

@Suite("JellyfinAPIError Tests")
@MainActor
struct JellyfinAPIErrorTests {
    @Test("Static error descriptions", arguments: [
        (JellyfinAPIError.badURL, "The Jellyfin URL is not valid."),
        (.unauthorized, "Your Jellyfin credentials are no longer valid. Please sign in again."),
        (.invalidResponse, "Jellyfin returned an unexpected response."),
        (.notAdmin, "An administrator account is required to manage Jellyfin from Trawl.")
    ])
    func staticErrorDescriptions(error: JellyfinAPIError, expected: String) {
        #expect(error.errorDescription == expected)
    }

    @Test("Transport error embeds URL error description")
    func transportErrorDescription() {
        let urlError = URLError(.timedOut)
        let error = JellyfinAPIError.transport(urlError)
        let desc = error.errorDescription ?? ""
        #expect(desc.contains("Couldn't reach Jellyfin"))
    }

    @Test("Decode error includes reason")
    func decodeErrorDescription() {
        let error = JellyfinAPIError.decode(reason: "keyNotFound(\"Id\")")
        #expect(error.errorDescription == "Couldn't read Jellyfin response: keyNotFound(\"Id\")")
    }

    @Test("HTTP error with no body uses status-only message")
    func httpErrorNilBody() {
        let error = JellyfinAPIError.http(status: 500, body: nil)
        #expect(error.errorDescription == "Jellyfin returned status 500.")
    }

    @Test("HTTP error with empty body uses status-only message")
    func httpErrorEmptyBody() {
        let error = JellyfinAPIError.http(status: 503, body: "")
        #expect(error.errorDescription == "Jellyfin returned status 503.")
    }

    @Test("HTTP error with JSON Message field is extracted")
    func httpErrorWithMessageField() {
        let body = #"{"Message":"Item not found"}"#
        let error = JellyfinAPIError.http(status: 404, body: body)
        #expect(error.errorDescription == "Jellyfin returned 404: Item not found")
    }

    @Test("HTTP error with lowercase message field is extracted")
    func httpErrorWithLowercaseMessageField() {
        let body = #"{"message":"server overloaded"}"#
        let error = JellyfinAPIError.http(status: 503, body: body)
        #expect(error.errorDescription == "Jellyfin returned 503: server overloaded")
    }

    @Test("HTTP error with error field is extracted")
    func httpErrorWithErrorField() {
        let body = #"{"error":"unauthorized"}"#
        let error = JellyfinAPIError.http(status: 401, body: body)
        #expect(error.errorDescription == "Jellyfin returned 401: unauthorized")
    }

    @Test("HTTP error with non-JSON body falls back to status-only message")
    func httpErrorNonJSONBody() {
        let error = JellyfinAPIError.http(status: 502, body: "Bad Gateway")
        #expect(error.errorDescription == "Jellyfin returned status 502.")
    }

    @Test("HTTP error with JSON lacking known keys falls back to status-only")
    func httpErrorJSONNoKnownKeys() {
        let body = #"{"code":42,"detail":"something"}"#
        let error = JellyfinAPIError.http(status: 400, body: body)
        #expect(error.errorDescription == "Jellyfin returned status 400.")
    }
}

// MARK: - JellyfinAPIClient URL Trimming Tests

@Suite("JellyfinAPIClient URL Trimming Tests")
@MainActor
struct JellyfinAPIClientURLTests {
    @Test("Trailing slash is removed from baseURL", arguments: [
        ("http://jellyfin.local:8096/", "http://jellyfin.local:8096"),
        ("http://jellyfin.local:8096", "http://jellyfin.local:8096"),
        ("  http://jellyfin.local:8096/  ", "http://jellyfin.local:8096"),
        ("https://example.com/jellyfin/", "https://example.com/jellyfin")
    ])
    func baseURLTrimming(input: String, expected: String) async {
        let client = JellyfinAPIClient(baseURL: input)
        #expect(client.baseURL == expected)
    }

    @Test("directoryContentsParams includes all required keys")
    func directoryContentsParamsKeys() {
        let params = JellyfinAPIClient.directoryContentsParams(
            path: "/srv/media",
            includeFiles: true,
            includeDirectories: false
        )
        #expect(params["Path"] == "/srv/media")
        #expect(params["IncludeFiles"] == "true")
        #expect(params["IncludeDirectories"] == "false")
        #expect(params.count == 3)
    }

    @Test("directoryContentsParams with empty path")
    func directoryContentsParamsEmptyPath() {
        let params = JellyfinAPIClient.directoryContentsParams(
            path: "",
            includeFiles: false,
            includeDirectories: true
        )
        #expect(params["Path"] == "")
        #expect(params["IncludeFiles"] == "false")
        #expect(params["IncludeDirectories"] == "true")
    }
}

// MARK: - JellyfinLibraryItem Tests

@Suite("JellyfinLibraryItem Tests")
@MainActor
struct JellyfinLibraryItemTests {
    private func makeItem(
        id: String = "abc",
        name: String? = "Test Movie",
        productionYear: Int? = nil,
        runTimeTicks: Int64? = nil,
        providerIds: [String: String]? = nil,
        mediaSources: [[String: Any]]? = nil
    ) throws -> JellyfinLibraryItem {
        var json: [String: Any] = ["Id": id]
        if let name { json["Name"] = name }
        if let productionYear { json["ProductionYear"] = productionYear }
        if let runTimeTicks { json["RunTimeTicks"] = runTimeTicks }
        if let providerIds { json["ProviderIds"] = providerIds }
        if let mediaSources { json["MediaSources"] = mediaSources }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(JellyfinLibraryItem.self, from: data)
    }

    // MARK: providerID(for:)

    @Test("providerID exact key match")
    func providerIDExactMatch() throws {
        let item = try makeItem(providerIds: ["Tmdb": "12345", "Imdb": "tt0000001"])
        #expect(item.providerID(for: ["Tmdb"]) == "12345")
        #expect(item.providerID(for: ["Imdb"]) == "tt0000001")
    }

    @Test("providerID case-insensitive key match")
    func providerIDCaseInsensitiveMatch() throws {
        let item = try makeItem(providerIds: ["tmdb": "99999"])
        #expect(item.providerID(for: ["Tmdb"]) == "99999")
        #expect(item.providerID(for: ["TMDB"]) == "99999")
    }

    @Test("providerID returns first matching key from list")
    func providerIDFirstMatch() throws {
        let item = try makeItem(providerIds: ["Imdb": "tt1234567"])
        // Tmdb is not present, should fall through to Imdb
        #expect(item.providerID(for: ["Tmdb", "Imdb"]) == "tt1234567")
    }

    @Test("providerID returns nil when key not found")
    func providerIDNotFound() throws {
        let item = try makeItem(providerIds: ["Tvdb": "12345"])
        #expect(item.providerID(for: ["Tmdb", "Imdb"]) == nil)
    }

    @Test("providerID returns nil when providerIds is nil")
    func providerIDNilDict() throws {
        let item = try makeItem(providerIds: nil)
        #expect(item.providerID(for: ["Tmdb"]) == nil)
    }

    @Test("providerID skips empty values")
    func providerIDSkipsEmptyValues() throws {
        let item = try makeItem(providerIds: ["Tmdb": "", "Imdb": "tt9999999"])
        // Tmdb is empty so providerID should skip it and return nil (only Tmdb searched)
        #expect(item.providerID(for: ["Tmdb"]) == nil)
        // Searching Imdb should return the non-empty value
        #expect(item.providerID(for: ["Imdb"]) == "tt9999999")
    }

    // MARK: providerIDSummary

    @Test("providerIDSummary returns No provider IDs when nil")
    func providerIDSummaryNil() throws {
        let item = try makeItem(providerIds: nil)
        #expect(item.providerIDSummary == "No provider IDs")
    }

    @Test("providerIDSummary returns No provider IDs when empty dict")
    func providerIDSummaryEmpty() throws {
        let item = try makeItem(providerIds: [:])
        #expect(item.providerIDSummary == "No provider IDs")
    }

    @Test("providerIDSummary formats key-value pairs sorted alphabetically")
    func providerIDSummarySorted() throws {
        let item = try makeItem(providerIds: ["Tmdb": "12345", "Imdb": "tt0000001"])
        // Alphabetical: Imdb before Tmdb
        #expect(item.providerIDSummary == "Imdb: tt0000001 · Tmdb: 12345")
    }

    // MARK: fileSize

    @Test("fileSize returns first media source size")
    func fileSizeFromMediaSource() throws {
        let sources: [[String: Any]] = [
            ["Id": "1", "Size": 5_000_000_000]
        ]
        let item = try makeItem(mediaSources: sources)
        #expect(item.fileSize == 5_000_000_000)
    }

    @Test("fileSize returns nil when no media sources")
    func fileSizeNilNoMediaSources() throws {
        let item = try makeItem(mediaSources: nil)
        #expect(item.fileSize == nil)
    }

    @Test("fileSize returns nil when media source has no size")
    func fileSizeNilNoSize() throws {
        let sources: [[String: Any]] = [["Id": "1"]]
        let item = try makeItem(mediaSources: sources)
        #expect(item.fileSize == nil)
    }

    // MARK: runtimeMinutes

    @Test("runtimeMinutes converts ticks to minutes")
    func runtimeMinutesFromTicks() throws {
        // 90 minutes = 90 * 60 * 10_000_000 = 54_000_000_000 ticks
        let item = try makeItem(runTimeTicks: 54_000_000_000)
        #expect(item.runtimeMinutes == 90)
    }

    @Test("runtimeMinutes returns nil for zero ticks")
    func runtimeMinutesZeroTicks() throws {
        let item = try makeItem(runTimeTicks: 0)
        #expect(item.runtimeMinutes == nil)
    }

    @Test("runtimeMinutes returns nil when runTimeTicks is absent")
    func runtimeMinutesNilTicks() throws {
        let item = try makeItem(runTimeTicks: nil)
        #expect(item.runtimeMinutes == nil)
    }

    @Test("runtimeMinutes rounds to nearest minute")
    func runtimeMinutesRounding() throws {
        // 90.5 minutes = 54_300_000_000 ticks -> rounds to 91
        let item = try makeItem(runTimeTicks: 54_300_000_000)
        #expect(item.runtimeMinutes == 91)
    }
}

// MARK: - JellyfinFileSystemEntryInfo Tests

@Suite("JellyfinFileSystemEntryInfo Tests")
@MainActor
struct JellyfinFileSystemEntryInfoTests {
    @Test("Parent type is treated as directory with parent kind")
    func parentTypeKind() throws {
        let json = #"{"Name":"..","Path":"/mnt","Type":"Parent"}"#
        let data = try #require(json.data(using: .utf8))
        let entry = try JSONDecoder().decode(JellyfinFileSystemEntryInfo.self, from: data)
        #expect(entry.remotePathEntry.kind == .parent)
        #expect(entry.isDirectory)
    }

    @Test("Unknown type defaults to directory kind")
    func unknownTypeDefaultsToDirectory() throws {
        let json = #"{"Name":"Misc","Path":"/misc","Type":"SomethingElse"}"#
        let data = try #require(json.data(using: .utf8))
        let entry = try JSONDecoder().decode(JellyfinFileSystemEntryInfo.self, from: data)
        #expect(entry.isDirectory)
        #expect(entry.remotePathEntry.kind == .directory)
    }

    @Test("displayName falls back to last path component when name is nil")
    func displayNameFromPath() throws {
        let json = #"{"Path":"/mnt/media/shows","Type":"Directory"}"#
        let data = try #require(json.data(using: .utf8))
        let entry = try JSONDecoder().decode(JellyfinFileSystemEntryInfo.self, from: data)
        #expect(entry.remotePathEntry.name == "shows")
    }

    @Test("displayName falls back to last path component when name is empty")
    func displayNameFromPathWhenEmpty() throws {
        let json = #"{"Name":"","Path":"/mnt/media/movies","Type":"Directory"}"#
        let data = try #require(json.data(using: .utf8))
        let entry = try JSONDecoder().decode(JellyfinFileSystemEntryInfo.self, from: data)
        #expect(entry.remotePathEntry.name == "movies")
    }

    @Test("id equals path")
    func idEqualsPath() throws {
        let json = #"{"Name":"Media","Path":"/srv/media","Type":"Directory"}"#
        let data = try #require(json.data(using: .utf8))
        let entry = try JSONDecoder().decode(JellyfinFileSystemEntryInfo.self, from: data)
        #expect(entry.id == "/srv/media")
    }

    @Test("Type is case-insensitive for kind mapping", arguments: [
        (#"{"Name":"dir","Path":"/dir","Type":"directory"}"#, RemotePathEntryKind.directory),
        (#"{"Name":"drv","Path":"C:\\","Type":"drive"}"#, RemotePathEntryKind.drive),
        (#"{"Name":"nas","Path":"\\\\nas","Type":"networkshare"}"#, RemotePathEntryKind.networkShare),
        (#"{"Name":"file","Path":"/a.mkv","Type":"file"}"#, RemotePathEntryKind.file)
    ])
    func kindCaseInsensitive(json: String, expectedKind: RemotePathEntryKind) throws {
        let data = try #require(json.data(using: .utf8))
        let entry = try JSONDecoder().decode(JellyfinFileSystemEntryInfo.self, from: data)
        #expect(entry.remotePathEntry.kind == expectedKind)
    }
}

// MARK: - JellyfinVirtualFolder Tests

@Suite("JellyfinVirtualFolder Tests")
@MainActor
struct JellyfinVirtualFolderTests {
    private func makeFolder(collectionType: String?) throws -> JellyfinVirtualFolder {
        var json: [String: Any] = [
            "Name": "My Library",
            "Locations": ["/media"],
            "ItemId": "abc123"
        ]
        if let collectionType { json["CollectionType"] = collectionType }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(JellyfinVirtualFolder.self, from: data)
    }

    @Test("collectionIcon for known types", arguments: [
        ("movies", "film"),
        ("tvshows", "tv"),
        ("music", "music.note"),
        ("books", "book"),
        ("homevideos", "house"),
        ("musicvideos", "music.note.list"),
        ("mixed", "square.grid.2x2")
    ])
    func collectionIconKnownTypes(type: String, expectedIcon: String) throws {
        let folder = try makeFolder(collectionType: type)
        #expect(folder.collectionIcon == expectedIcon)
    }

    @Test("collectionIcon for unknown type defaults to folder")
    func collectionIconUnknownType() throws {
        let folder = try makeFolder(collectionType: "unknown")
        #expect(folder.collectionIcon == "folder")
    }

    @Test("collectionIcon for nil type defaults to folder")
    func collectionIconNilType() throws {
        let folder = try makeFolder(collectionType: nil)
        #expect(folder.collectionIcon == "folder")
    }

    @Test("id equals itemId")
    func idEqualsItemId() throws {
        let folder = try makeFolder(collectionType: "movies")
        #expect(folder.id == "abc123")
    }
}

// MARK: - JellyfinNowPlayingItem Tests

@Suite("JellyfinNowPlayingItem Tests")
@MainActor
struct JellyfinNowPlayingItemTests {
    private func makeItem(
        name: String? = nil,
        type: String? = nil,
        runTimeTicks: Int64? = nil,
        seriesName: String? = nil,
        seasonName: String? = nil,
        indexNumber: Int? = nil
    ) throws -> JellyfinNowPlayingItem {
        var json: [String: Any] = [:]
        if let name { json["Name"] = name }
        if let type { json["Type"] = type }
        if let runTimeTicks { json["RunTimeTicks"] = runTimeTicks }
        if let seriesName { json["SeriesName"] = seriesName }
        if let seasonName { json["SeasonName"] = seasonName }
        if let indexNumber { json["IndexNumber"] = indexNumber }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(JellyfinNowPlayingItem.self, from: data)
    }

    @Test("episodeDetail with season and episode")
    func episodeDetailBoth() throws {
        let item = try makeItem(seasonName: "Season 1", indexNumber: 3)
        #expect(item.episodeDetail == "Season 1 — Episode 3")
    }

    @Test("episodeDetail with only seasonName")
    func episodeDetailSeasonOnly() throws {
        let item = try makeItem(seasonName: "Season 2")
        #expect(item.episodeDetail == "Season 2")
    }

    @Test("episodeDetail with only indexNumber")
    func episodeDetailEpisodeOnly() throws {
        let item = try makeItem(indexNumber: 5)
        #expect(item.episodeDetail == "Episode 5")
    }

    @Test("episodeDetail nil when neither season nor episode")
    func episodeDetailNil() throws {
        let item = try makeItem()
        #expect(item.episodeDetail == nil)
    }

    @Test("formattedDuration for hours and minutes")
    func formattedDurationHours() throws {
        // 1h 23m = 83 * 60 * 10_000_000 = 49_800_000_000 ticks
        let item = try makeItem(runTimeTicks: 49_800_000_000)
        #expect(item.formattedDuration == "1h 23m")
    }

    @Test("formattedDuration for minutes only")
    func formattedDurationMinutes() throws {
        // 45m = 45 * 60 * 10_000_000 = 27_000_000_000 ticks
        let item = try makeItem(runTimeTicks: 27_000_000_000)
        #expect(item.formattedDuration == "45m")
    }

    @Test("formattedDuration empty for zero ticks")
    func formattedDurationZero() throws {
        let item = try makeItem(runTimeTicks: 0)
        #expect(item.formattedDuration == "")
    }

    @Test("formattedDuration empty for nil ticks")
    func formattedDurationNil() throws {
        let item = try makeItem(runTimeTicks: nil)
        #expect(item.formattedDuration == "")
    }

    @Test("mediaType falls back to Unknown when type is nil")
    func mediaTypeFallback() throws {
        let item = try makeItem(type: nil)
        #expect(item.mediaType == "Unknown")
    }

    @Test("mediaType returns type when present")
    func mediaTypePresent() throws {
        let item = try makeItem(type: "Episode")
        #expect(item.mediaType == "Episode")
    }
}

// MARK: - JellyfinSession Tests

@Suite("JellyfinSession Tests")
@MainActor
struct JellyfinSessionTests {
    private func makeSession(
        id: String = "sess1",
        nowPlayingItem: [String: Any]? = nil,
        positionTicks: Int64? = nil,
        runTimeTicks: Int64? = nil
    ) throws -> JellyfinSession {
        var json: [String: Any] = ["Id": id]
        if let nowPlayingItem {
            var npi = nowPlayingItem
            if let runTimeTicks { npi["RunTimeTicks"] = runTimeTicks }
            json["NowPlayingItem"] = npi
        }
        if let positionTicks {
            json["PlayState"] = ["PositionTicks": positionTicks]
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(JellyfinSession.self, from: data)
    }

    @Test("isActive true when nowPlayingItem is present")
    func isActiveTrue() throws {
        let session = try makeSession(nowPlayingItem: ["Name": "Test Movie"])
        #expect(session.isActive)
    }

    @Test("isActive false when nowPlayingItem is absent")
    func isActiveFalse() throws {
        let session = try makeSession()
        #expect(!session.isActive)
    }

    @Test("progressFraction computes correctly")
    func progressFraction() throws {
        // Position 30m / total 90m = 0.333...
        // 30m = 18_000_000_000 ticks, 90m = 54_000_000_000 ticks
        let session = try makeSession(
            nowPlayingItem: ["Name": "Test Movie"],
            positionTicks: 18_000_000_000,
            runTimeTicks: 54_000_000_000
        )
        let fraction = session.progressFraction
        #expect(fraction > 0.33 && fraction < 0.34)
    }

    @Test("progressFraction is 0 when no now playing item")
    func progressFractionNoNowPlaying() throws {
        let session = try makeSession(positionTicks: 10_000_000_000)
        #expect(session.progressFraction == 0)
    }

    @Test("progressFraction is capped at 1.0")
    func progressFractionCappedAtOne() throws {
        // Position ticks > run time ticks
        let session = try makeSession(
            nowPlayingItem: ["Name": "Test"],
            positionTicks: 100_000_000_000,
            runTimeTicks: 10_000_000_000
        )
        #expect(session.progressFraction <= 1.0)
    }
}

// MARK: - JellyfinScheduledTask Tests

@Suite("JellyfinScheduledTask Tests")
@MainActor
struct JellyfinScheduledTaskTests {
    private func makeTask(state: String) throws -> JellyfinScheduledTask {
        let json: [String: Any] = ["Id": "task1", "Name": "Scan Library", "State": state]
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(JellyfinScheduledTask.self, from: data)
    }

    @Test("isRunning true only for Running state", arguments: [
        ("Running", true, false, false),
        ("Idle", false, true, false),
        ("Cancelling", false, false, true),
        ("Unknown", false, false, false)
    ])
    func stateProperties(state: String, isRunning: Bool, isIdle: Bool, isCancelling: Bool) throws {
        let task = try makeTask(state: state)
        #expect(task.isRunning == isRunning)
        #expect(task.isIdle == isIdle)
        #expect(task.isCancelling == isCancelling)
    }

    @Test("stateBadge matches state for Running and Cancelling, Idle otherwise", arguments: [
        ("Running", "Running"),
        ("Cancelling", "Cancelling"),
        ("Idle", "Idle"),
        ("Queued", "Idle")
    ])
    func stateBadge(state: String, expectedBadge: String) throws {
        let task = try makeTask(state: state)
        #expect(task.stateBadge == expectedBadge)
    }
}

// MARK: - JellyfinScheduledTaskResult Tests

@Suite("JellyfinScheduledTaskResult Tests")
@MainActor
struct JellyfinScheduledTaskResultTests {
    private func makeResult(status: String?) throws -> JellyfinScheduledTaskResult {
        var json: [String: Any] = [:]
        if let status { json["Status"] = status }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(JellyfinScheduledTaskResult.self, from: data)
    }

    @Test("isSuccess true only for Completed status", arguments: [
        ("Completed", true, false),
        ("Failed", false, true),
        ("Cancelled", false, true),
        ("Unknown", false, false)
    ])
    func successFailureStatus(status: String, isSuccess: Bool, isFailure: Bool) throws {
        let result = try makeResult(status: status)
        #expect(result.isSuccess == isSuccess)
        #expect(result.isFailure == isFailure)
    }

    @Test("statusBadge reflects status value", arguments: [
        ("Completed", "Completed"),
        ("Failed", "Failed"),
        ("Cancelled", "Cancelled"),
        ("Queued", "Queued")
    ])
    func statusBadge(status: String, expectedBadge: String) throws {
        let result = try makeResult(status: status)
        #expect(result.statusBadge == expectedBadge)
    }

    @Test("statusBadge is Unknown when status is nil")
    func statusBadgeNil() throws {
        let result = try makeResult(status: nil)
        #expect(result.statusBadge == "Unknown")
    }
}

// MARK: - JellyfinActivityEntry Tests

@Suite("JellyfinActivityEntry Tests")
@MainActor
struct JellyfinActivityEntryTests {
    private func makeEntry(severity: String?) throws -> JellyfinActivityEntry {
        var json: [String: Any] = ["Id": 1, "Name": "Test Event", "Date": "2024-01-01T00:00:00Z"]
        if let severity { json["Severity"] = severity }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(JellyfinActivityEntry.self, from: data)
    }

    @Test("severityIcon for error and fatal", arguments: ["Error", "Fatal", "error", "fatal"])
    func severityIconError(severity: String) throws {
        let entry = try makeEntry(severity: severity)
        #expect(entry.severityIcon == "xmark.circle.fill")
    }

    @Test("severityIcon for warning variants", arguments: ["Warning", "Warn", "warning", "warn"])
    func severityIconWarning(severity: String) throws {
        let entry = try makeEntry(severity: severity)
        #expect(entry.severityIcon == "exclamationmark.triangle.fill")
    }

    @Test("severityIcon defaults to info for other values", arguments: [
        "Information", "Debug", nil as String?
    ])
    func severityIconDefault(severity: String?) throws {
        let entry = try makeEntry(severity: severity)
        #expect(entry.severityIcon == "info.circle.fill")
    }
}
