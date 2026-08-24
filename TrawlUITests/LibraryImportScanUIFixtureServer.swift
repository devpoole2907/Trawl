//
//  LibraryImportScanUIFixtureServer.swift
//  TrawlUITests
//
//  Loopback Sonarr fixture for LibraryImportScanJourneyUITests. It models the
//  real Sonarr handshake plus the manual-import, library-status, and catalog
//  lookup requests that LibraryImportScanViewModel makes.

import Foundation
import Network

final class LibraryImportScanUIFixtureServer: @unchecked Sendable {
    struct RecordedRequest: Sendable, Equatable {
        let method: String
        let path: String
        let rawQuery: String
        let headers: [String: String]
        let body: String

        var queryItems: [URLQueryItem] {
            URLComponents(string: "http://127.0.0.1/?\(rawQuery)")?.queryItems ?? []
        }

        func values(for name: String) -> [String] {
            queryItems.filter { $0.name == name }.compactMap(\.value)
        }
    }

    enum Scenario: Sendable {
        case groupedSelection
        case blockedCatalogSearch
    }

    static let rootFolderPath = "/fixture/import-library"
    static let seriesID = 100
    static let seriesTitle = "Fixture Import Series"
    static let catalogTitle = "Fixture Catalog Match"
    static let readyFileName = "Fixture.Import.Series.S01E02.1080p.mkv"
    static let existingFileName = "Fixture.Import.Series.S01E01.1080p.mkv"
    static let blockedFileName = "Fixture.Catalog.Candidate.S01E01.1080p.mkv"

    private let listener: NWListener
    private let queue: DispatchQueue
    private let scenario: Scenario
    private let lock = NSLock()
    private var recordedRequests: [RecordedRequest] = []

    init(scenario: Scenario) async throws {
        self.scenario = scenario
        queue = DispatchQueue(label: "LibraryImportScanUIFixtureServer")
        listener = try NWListener(using: .tcp, on: .any)

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    var baseURL: String {
        guard let port = listener.port else {
            fatalError("Library Import Scan fixture server did not bind a port.")
        }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    var requests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func stop() {
        listener.cancel()
    }

    // MARK: HTTP server

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else {
                connection.cancel()
                return
            }

            var received = buffer
            if let data, !data.isEmpty {
                received.append(data)
            }

            if let request = Self.parseRequest(from: received) {
                lock.lock()
                recordedRequests.append(request)
                lock.unlock()

                let response = Self.httpResponse(body: responseBody(for: request))
                connection.send(
                    content: response,
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { _ in connection.cancel() }
                )
            } else if error != nil || complete {
                connection.cancel()
            } else {
                receive(on: connection, buffer: received)
            }
        }
    }

    private func responseBody(for request: RecordedRequest) -> String {
        switch (request.method, request.path) {
        case ("GET", "/api/v3/system/status"):
            return "{}"
        case ("GET", "/api/v3/qualityprofile"):
            return #"[{"id":1,"name":"Fixture Quality"}]"#
        case ("GET", "/api/v3/rootfolder"):
            return #"[{"id":1,"path":"\#(Self.rootFolderPath)","accessible":true}]"#
        case ("GET", "/api/v3/tag"):
            return "[]"
        case ("GET", "/api/v3/series"):
            return seriesJSON
        case ("GET", "/api/v3/episode"):
            return episodeJSON
        case ("GET", "/api/v3/manualimport"):
            return manualImportJSON
        case ("GET", "/api/v3/series/lookup"):
            return catalogJSON
        default:
            // Calendar and background prefetches are outside this journey. Returning
            // a valid empty collection keeps them from obscuring its real request
            // boundaries while still exercising the unmodified production client.
            return "[]"
        }
    }

    private var seriesJSON: String {
        #"[{"id":\#(Self.seriesID),"title":"\#(Self.seriesTitle)","tvdbId":700,"titleSlug":"fixture-import-series","path":"\#(Self.rootFolderPath)/\#(Self.seriesTitle)","monitored":true,"statistics":{"seasonCount":1,"episodeCount":2,"episodeFileCount":1}}]"#
    }

    /// Episode one deliberately has a file and episode two does not. The scan
    /// returns both files, so `loadInLibraryStatus()` must split them into its
    /// "extra" and "ready" presentation groups instead of trusting scan metadata.
    private var episodeJSON: String {
        #"[{"id":1001,"seriesId":\#(Self.seriesID),"seasonNumber":1,"episodeNumber":1,"title":"Existing Fixture Episode","hasFile":true},{"id":1002,"seriesId":\#(Self.seriesID),"seasonNumber":1,"episodeNumber":2,"title":"New Fixture Episode","hasFile":false}]"#
    }

    private var manualImportJSON: String {
        switch scenario {
        case .groupedSelection:
            return #"""
            [
              {"path":"\#(Self.rootFolderPath)/\#(Self.seriesTitle)/\#(Self.existingFileName)","name":"\#(Self.existingFileName)","size":1024,"series":{"id":\#(Self.seriesID),"title":"\#(Self.seriesTitle)","tvdbId":700},"seasonNumber":1,"episodes":[{"id":1001,"episodeNumber":1,"title":"Existing Fixture Episode"}],"quality":{"quality":{"name":"WEB 1080p"}}},
              {"path":"\#(Self.rootFolderPath)/\#(Self.seriesTitle)/\#(Self.readyFileName)","name":"\#(Self.readyFileName)","size":2048,"series":{"id":\#(Self.seriesID),"title":"\#(Self.seriesTitle)","tvdbId":700},"seasonNumber":1,"episodes":[{"id":1002,"episodeNumber":2,"title":"New Fixture Episode"}],"quality":{"quality":{"name":"WEB 1080p"}}}
            ]
            """#
        case .blockedCatalogSearch:
            return #"""
            [{"path":"\#(Self.rootFolderPath)/\#(Self.blockedFileName)","name":"\#(Self.blockedFileName)","size":512,"rejections":["Fixture requires identification"],"seasonNumber":1,"episodes":[{"id":2001,"episodeNumber":1,"title":"Unknown"}]}]
            """#
        }
    }

    private var catalogJSON: String {
        #"[{"id":0,"title":"\#(Self.catalogTitle)","tvdbId":701,"titleSlug":"fixture-catalog-match","seasons":[{"seasonNumber":1,"monitored":true}]}]"#
    }

    // MARK: Request parsing

    private static func parseRequest(from data: Data) -> RecordedRequest? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: data[data.startIndex..<headerRange.lowerBound], encoding: .utf8) else {
            return nil
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        var contentLength = 0
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
            if name == "content-length" {
                contentLength = Int(value) ?? 0
            }
        }

        let bodyStart = headerRange.upperBound
        guard data.distance(from: bodyStart, to: data.endIndex) >= contentLength else {
            return nil
        }
        let bodyEnd = data.index(bodyStart, offsetBy: contentLength)
        let body = String(data: data[bodyStart..<bodyEnd], encoding: .utf8) ?? ""

        let target = String(requestParts[1])
        let targetParts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        return RecordedRequest(
            method: String(requestParts[0]),
            path: String(targetParts.first ?? ""),
            rawQuery: targetParts.count > 1 ? String(targetParts[1]) : "",
            headers: headers,
            body: body
        )
    }

    private static func httpResponse(body: String) -> Data {
        let bodyData = Data(body.utf8)
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        return Data(headers.utf8) + bodyData
    }
}
