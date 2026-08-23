//
//  RadarrFixtureServer.swift
//  TrawlUITests
//
//  A real loopback HTTP server the UI test process hosts on `NWListener`, modeled on
//  `SonarrFixtureServer`'s NWListener/lock/`Connection: close` pattern (itself modeled
//  on `TrawlTests/ArrClientLifecycleTests.swift`'s `LifecycleArrTestServer`), but with
//  its own request-body buffering (from `ArrSearchAddFixtureServer`) because
//  `RadarrJourneyUITests` needs to inspect what a real `PUT /api/v3/movie/{id}` body
//  actually contains — something the simpler single-`receive` fixtures never had to do.
//
//  Production routes this answers (read from source, not guessed):
//  - Radarr connect sequence (`ArrServiceManager.connectService`'s `.radarr` branch,
//    `Trawl/ArrStack/ArrServiceManager.swift`): `GET /api/v3/system/status`, `GET
//    /api/v3/qualityprofile`, `GET /api/v3/rootfolder`, `GET /api/v3/tag` — all via
//    `SharedArrClient`'s default implementations (`Trawl/ArrStack/ArrAPIClient.swift`).
//  - `GET /api/v3/movie` — the movie library (`ArrServiceManager.loadMovieLibrary`,
//    `RadarrAPIClient.getMovies`, `Trawl/ArrStack/RadarrAPIClient.swift:15`).
//  - `GET /api/v3/movie/{id}` — the canonical single-movie fetch
//    (`RadarrAPIClient.getMovie(id:)`, `RadarrAPIClient.swift:20`), called by
//    `RadarrViewModel.toggleMovieMonitored(_:)`
//    (`Trawl/ArrStack/RadarrViewModel.swift:267`) before it can build the updated
//    movie to PUT — this fixture must serve a movie with a non-nil `qualityProfileId`
//    and a non-empty `rootFolderPath`, or `toggleMovieMonitored` bails out early
//    (`RadarrViewModel.swift:268-273`) without ever sending the PUT.
//  - `PUT /api/v3/movie/{id}` — the update itself (`RadarrAPIClient.updateMovie(_:
//    moveFiles:)`, `RadarrAPIClient.swift:48`), sent by `toggleMovieMonitored` with
//    the flipped `monitored` flag. This fixture parses the request body's `monitored`
//    field and remembers it, so every subsequent `GET /api/v3/movie` and `GET
//    /api/v3/movie/{id}` reflects the new state — mirroring real Radarr closely
//    enough that the app's post-update `loadMovies()` refetch actually sees the flip.
//  - `GET /api/v3/moviefile?movieId={id}` — `RadarrViewModel.loadMovieFiles(movieId:)`
//    (`RadarrViewModel.swift:121`), fired by `RadarrMovieDetailView`'s
//    `.task(id: resolvedLibraryId)` (`RadarrMovieDetailView.swift:294-330`).
//  - `GET /api/v3/queue`, `GET /api/v3/history` — polled by that same task and by
//    `ArrServiceManager.refreshQueues()`; both decode as paged *objects* (not bare
//    arrays — `ArrQueuePage`/`ArrHistoryPage`, `Trawl/ArrStack/ArrSharedModels.swift`),
//    so this fixture answers `{}` rather than the `[]` a plain-array endpoint gets.
//  - `GET /api/v3/blocklist` — same paged-object shape (`ArrBlocklistPage`), polled by
//    `ArrServiceManager.loadBlocklist()` right after connect.
//  - Anything else the app may also issue (health checks, calendar prefetches from
//    `ArrCalendarViewModel.refresh()`, etc.) gets a harmless empty-array `200 OK`,
//    matching `SonarrFixtureServer`'s convention — none of it is relevant to what
//    `RadarrJourneyUITests` asserts.
//
//  ## The fixture movie
//
//  `RadarrMovieDetailView` is 1,952 lines at 0% coverage before this suite, and a
//  movie payload with only a couple of fields would leave most of it rendering
//  nothing — see `TrawlTests/LiveCapturedShapeContractTests.swift` for a documented
//  case of a hand-written fixture's field gap hiding real behavior. `movieJSON()`
//  below fills in every field `RadarrMovieDetailView` actually reads (read from
//  `Trawl/ArrStack/RadarrMovieDetailView.swift` and `Trawl/ArrStack/RadarrModels.swift`
//  directly): title, studio, year, runtime, genres, and badges for `heroSection`;
//  `ratings` for `ratingsCard`; `overview` for `ArrDetailOverviewCard`; `runtime`,
//  `sizeOnDisk`, and `displayStatus` (via `hasFile`/`status`) for `statsCard`;
//  `inCinemas`/`digitalRelease`/`physicalRelease` for `releaseDatesCard`; `path`,
//  `imdbId`, `tmdbId` for `infoCard`; `collection` for `collectionCard`;
//  `youTubeTrailerId` for `trailerCard`; and `alternateTitles` for
//  `ArrDetailAlternateTitlesCard`. The known constants below (`movieId`,
//  `movieTitle`, `movieStudio`, `movieOverview`, `movieYear`) are exposed so
//  `RadarrJourneyUITests` can assert against exactly what the fixture serves rather
//  than a copy that could drift.

import Foundation
import Network

/// Loopback fixture standing in for a real Radarr server, purpose-built for
/// `RadarrJourneyUITests`. Distinct type names from `SonarrFixtureServer` /
/// `ArrSearchAddFixtureServer` even though the shape rhymes, since this fixture is
/// mutable (it remembers the `monitored` flag a `PUT` changes) in a way neither of
/// those needs to be for their own journeys.
final class RadarrFixtureServer: @unchecked Sendable {
    struct RecordedRequest: Sendable, Equatable {
        let method: String
        let path: String
        let body: String
    }

    // MARK: - Fixture movie constants
    // Exposed so `RadarrJourneyUITests` asserts against the exact values this fixture
    // serves, rather than a hand-copied duplicate that could silently drift.

    static let movieId = 501
    static let movieTitle = "Fixture Movie: Trawl Signal"
    static let movieStudio = "Fixture Pictures"
    static let movieYear = 2024
    static let movieRuntime = 118
    static let movieOverview =
        "A fixture movie used to exercise RadarrMovieDetailView end-to-end, from the real GET /api/v3/movie library load through a real PUT /api/v3/movie/501 update."
    static let movieImdbId = "tt9990011"
    static let movieTmdbId = 424242
    static let movieQualityProfileId = 4
    static let movieRootFolderPath = "/movies"

    private let listener: NWListener
    private let queue: DispatchQueue

    private let qualityProfilesJSON: String
    private let rootFoldersJSON: String

    private let lock = NSLock()
    private var recordedRequests: [RecordedRequest] = []
    /// The only piece of server-side state a real Radarr would also hold across
    /// these requests: whether the fixture movie is currently monitored. Mutated by
    /// a `PUT /api/v3/movie/{id}` and read back by every subsequent `GET`.
    private var monitored: Bool

    /// - Parameters:
    ///   - initiallyMonitored: starting value of the fixture movie's `monitored`
    ///     flag. `RadarrJourneyUITests` uses the default (`true`) so its one
    ///     Radarr-specific action test can exercise the "Unmonitor" path.
    ///   - qualityProfilesJSON: served for `GET /api/v3/qualityprofile`. Defaults to
    ///     one profile whose `id` matches `movieQualityProfileId`, matching real
    ///     Radarr closely enough that a movie's `qualityProfileId` always resolves.
    ///   - rootFoldersJSON: served for `GET /api/v3/rootfolder`, matching
    ///     `movieRootFolderPath` by default for the same reason.
    init(
        initiallyMonitored: Bool = true,
        qualityProfilesJSON: String = #"[{"id":4,"name":"HD-1080p"}]"#,
        rootFoldersJSON: String = #"[{"id":1,"path":"/movies"}]"#
    ) async throws {
        self.queue = DispatchQueue(label: "RadarrFixtureServer")
        self.listener = try NWListener(using: .tcp, on: .any)
        self.monitored = initiallyMonitored
        self.qualityProfilesJSON = qualityProfilesJSON
        self.rootFoldersJSON = rootFoldersJSON

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.resume()
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// The base URL the app should be launched with, via
    /// `TRAWL_UITEST_RADARR_BASE_URL`.
    var baseURL: String {
        guard let port = listener.port else {
            fatalError("RadarrFixtureServer did not bind a port.")
        }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    /// Every request received so far, in arrival order. Thread-safe: connections can
    /// land concurrently (the connect sequence, the detail screen's queue poll, and
    /// the toggle-monitored action can all overlap), so every read/append of
    /// `recordedRequests` goes through `lock`.
    var requests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func hasReceivedRequest(method: String, path: String) -> Bool {
        requests.contains { $0.method == method && $0.path == path }
    }

    func requestCount(method: String, path: String) -> Int {
        requests.filter { $0.method == method && $0.path == path }.count
    }

    func stop() {
        listener.cancel()
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    /// Accumulates received bytes until a full HTTP request — headers plus a body
    /// exactly as long as its declared `Content-Length` — has arrived, rather than
    /// assuming a bodyless `GET` fits in one `NWConnection.receive` callback (which
    /// is all `SonarrFixtureServer` needs, but not the `PUT` this fixture has to
    /// parse). Mirrors `ArrSearchAddFixtureServer.receive(on:buffer:)`.
    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var next = buffer
            if let data, !data.isEmpty {
                next.append(data)
            }

            if let request = Self.parseRequest(from: next) {
                self.handle(request, on: connection)
            } else if error != nil || (isComplete && (data == nil || data!.isEmpty)) {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: next)
            }
        }
    }

    private func handle(_ request: RecordedRequest, on connection: NWConnection) {
        lock.lock()
        recordedRequests.append(request)
        lock.unlock()

        let body = responseBody(for: request)
        connection.send(
            content: Self.httpResponse(body: body),
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    // MARK: - Route table

    /// Routing is deliberately written as `if`/`else if` on `request.method` and
    /// `request.path` rather than a `switch` over the tuple: the single-movie detail
    /// path (`/api/v3/movie/{id}`) is only known at runtime (`Self.movieId`), and a
    /// `switch` case matching against a pre-bound `let` requires relying on Swift's
    /// expression-pattern-vs-binding-pattern distinction, which is easy to get wrong
    /// by eye in review — an explicit `==` comparison here can't be misread.
    private func responseBody(for request: RecordedRequest) -> String {
        let movieDetailPath = "/api/v3/movie/\(Self.movieId)"

        if request.method == "GET" && request.path == "/api/v3/system/status" {
            return "{}"
        }
        if request.method == "GET" && request.path == "/api/v3/qualityprofile" {
            return qualityProfilesJSON
        }
        if request.method == "GET" && request.path == "/api/v3/rootfolder" {
            return rootFoldersJSON
        }
        if request.method == "GET" && request.path == "/api/v3/tag" {
            return "[]"
        }
        if request.method == "GET" && request.path == "/api/v3/movie" {
            lock.lock()
            let json = "[\(movieJSON())]"
            lock.unlock()
            return json
        }
        if request.method == "GET" && request.path == movieDetailPath {
            lock.lock()
            let json = movieJSON()
            lock.unlock()
            return json
        }
        if request.method == "PUT" && request.path == movieDetailPath {
            if let bodyObject = try? JSONSerialization.jsonObject(with: Data(request.body.utf8)) as? [String: Any],
               let newMonitored = bodyObject["monitored"] as? Bool {
                lock.lock()
                monitored = newMonitored
                lock.unlock()
            }
            lock.lock()
            let json = movieJSON()
            lock.unlock()
            return json
        }
        if request.method == "GET" && request.path == "/api/v3/moviefile" {
            lock.lock()
            let json = "[\(movieFileJSON())]"
            lock.unlock()
            return json
        }
        // ArrQueuePage / ArrHistoryPage / ArrBlocklistPage all decode as paged
        // *objects*, not bare arrays — every field on each is optional, so an empty
        // object decodes to an empty page rather than throwing.
        if request.method == "GET",
           ["/api/v3/queue", "/api/v3/history", "/api/v3/blocklist"].contains(request.path) {
            return "{}"
        }
        // Anything else the app may also issue (health checks, calendar prefetches
        // from ArrCalendarViewModel.refresh(), etc.) gets a harmless empty-array
        // `200 OK`, matching SonarrFixtureServer's convention — none of it is
        // relevant to what RadarrJourneyUITests asserts.
        return "[]"
    }

    // MARK: - Fixture movie JSON

    /// Matches `RadarrMovie`'s `CodingKeys` field-for-field (`Trawl/ArrStack/
    /// RadarrModels.swift`), populated with everything `RadarrMovieDetailView`
    /// actually renders. Must be called with `lock` held (reads `monitored`).
    private func movieJSON() -> String {
        #"""
        {
          "id": \#(Self.movieId),
          "title": "\#(Self.movieTitle)",
          "originalTitle": "\#(Self.movieTitle)",
          "sortTitle": "fixture movie trawl signal",
          "sizeOnDisk": 15032385536,
          "overview": "\#(Self.movieOverview)",
          "inCinemas": "2024-05-01T00:00:00Z",
          "physicalRelease": "2024-08-01T00:00:00Z",
          "digitalRelease": "2024-07-01T00:00:00Z",
          "status": "released",
          "images": [
            {"coverType": "poster", "remoteUrl": "https://example.com/fixture-poster.jpg", "url": null},
            {"coverType": "fanart", "remoteUrl": "https://example.com/fixture-fanart.jpg", "url": null}
          ],
          "website": "https://example.com/fixture-movie",
          "year": \#(Self.movieYear),
          "hasFile": true,
          "youTubeTrailerId": "dQw4w9WgXcQ",
          "studio": "\#(Self.movieStudio)",
          "path": "/movies/Fixture Movie (2024)",
          "rootFolderPath": "\#(Self.movieRootFolderPath)",
          "qualityProfileId": \#(Self.movieQualityProfileId),
          "monitored": \#(monitored),
          "minimumAvailability": "released",
          "isAvailable": true,
          "folderName": "Fixture Movie (2024)",
          "runtime": \#(Self.movieRuntime),
          "cleanTitle": "fixturemovietrawlsignal",
          "imdbId": "\#(Self.movieImdbId)",
          "tmdbId": \#(Self.movieTmdbId),
          "titleSlug": "fixture-movie-trawl-signal-\#(Self.movieTmdbId)",
          "certification": "PG-13",
          "genres": ["Action", "Science Fiction"],
          "tags": [],
          "added": "2024-01-01T00:00:00Z",
          "ratings": {
            "imdb": {"votes": 1000, "value": 7.6, "type": "user"},
            "tmdb": {"votes": 500, "value": 7.8, "type": "user"},
            "rottenTomatoes": {"votes": 0, "value": 91, "type": "user"},
            "metacritic": {"votes": 0, "value": 75, "type": "user"}
          },
          "movieFile": \#(movieFileJSON()),
          "collection": {
            "name": "Fixture Trilogy",
            "tmdbId": 880001,
            "images": null
          },
          "popularity": 12.3,
          "statistics": {
            "movieFileCount": 1,
            "sizeOnDisk": 15032385536,
            "releaseGroups": ["FIXTURE"]
          },
          "alternateTitles": [
            {"sourceType": "tmdb", "movieMetadataId": 1, "title": "Alt Fixture Title", "id": 1}
          ]
        }
        """#
    }

    /// Matches `RadarrMovieFile`'s `CodingKeys`. Used both embedded in `movieJSON()`
    /// (`movie.movieFile`) and as the single element of `GET /api/v3/moviefile`'s
    /// array response (`RadarrViewModel.movieFiles`, `filesCard`).
    private func movieFileJSON() -> String {
        #"""
        {
          "id": 9001,
          "movieId": \#(Self.movieId),
          "relativePath": "Fixture Movie (2024).mkv",
          "path": "/movies/Fixture Movie (2024)/Fixture Movie (2024).mkv",
          "size": 15032385536,
          "dateAdded": "2024-01-02T00:00:00Z",
          "quality": null,
          "mediaInfo": {
            "audioBitrate": 384000,
            "audioChannels": 6,
            "audioCodec": "EAC3",
            "audioLanguages": "eng",
            "audioStreamCount": 1,
            "videoBitDepth": 8,
            "videoBitrate": 8000000,
            "videoCodec": "h264",
            "videoDynamicRangeType": "SDR",
            "videoFps": 23.976,
            "resolution": "1920x1080",
            "runTime": "1:58:00",
            "scanType": "Progressive",
            "subtitles": "eng"
          },
          "edition": null
        }
        """#
    }

    // MARK: - Request parsing

    /// Parses one HTTP/1.1 request out of `data`, returning `nil` when the buffer
    /// doesn't yet contain a full request (no header/body separator, or a
    /// `Content-Length` body that hasn't fully arrived) so the caller keeps reading.
    /// Mirrors `ArrSearchAddFixtureServer.parseRequest(from:)`.
    private static func parseRequest(from data: Data) -> RecordedRequest? {
        guard let separatorRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }
        guard let headerText = String(data: data[data.startIndex..<separatorRange.lowerBound], encoding: .utf8) else {
            return nil
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        let method = parts.first.map(String.init) ?? ""
        let rawPath = parts.dropFirst().first.map(String.init) ?? ""
        let path = String(rawPath.split(separator: "?", maxSplits: 1).first ?? "")

        var contentLength = 0
        for line in lines.dropFirst() {
            let headerParts = line.split(separator: ":", maxSplits: 1)
            guard headerParts.count == 2 else { continue }
            let name = headerParts[0].trimmingCharacters(in: .whitespaces)
            if name.caseInsensitiveCompare("Content-Length") == .orderedSame {
                contentLength = Int(headerParts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }

        let bodyStart = separatorRange.upperBound
        let bodyBytesAvailable = data.count - bodyStart
        guard bodyBytesAvailable >= contentLength else {
            return nil
        }

        let bodyEnd = data.index(bodyStart, offsetBy: contentLength)
        let bodyData = data[bodyStart..<bodyEnd]
        let body = String(data: bodyData, encoding: .utf8) ?? ""

        return RecordedRequest(method: method, path: path, body: body)
    }

    private static func httpResponse(body: String) -> Data {
        let bytes = Data(body.utf8)
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        return Data(headers.utf8) + bytes
    }
}
