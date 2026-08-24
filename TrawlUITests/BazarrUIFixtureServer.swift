//
//  BazarrUIFixtureServer.swift
//  TrawlUITests
//
//  A loopback Bazarr fixture for BazarrJourneyUITests. It supplies the real
//  Bazarr connection handshake plus the tracked-movie response consumed by
//  BazarrSubtitleStatusCard on a Radarr movie detail screen.

import Foundation
import Network

final class BazarrUIFixtureServer: @unchecked Sendable {
    struct RecordedRequest: Sendable, Equatable {
        let method: String
        let path: String
        let rawQuery: String
        let headers: [String: String]
    }

    static let languageProfileID = 71
    static let languageProfileName = "Fixture English"
    static let missingLanguageName = "English"
    static let missingLanguageCode = "en"

    private let listener: NWListener
    private let queue: DispatchQueue
    private let radarrMovieID: Int
    private let radarrMovieTitle: String

    private let lock = NSLock()
    private var recordedRequests: [RecordedRequest] = []

    init(radarrMovieID: Int, radarrMovieTitle: String) async throws {
        self.queue = DispatchQueue(label: "BazarrUIFixtureServer")
        self.listener = try NWListener(using: .tcp, on: .any)
        self.radarrMovieID = radarrMovieID
        self.radarrMovieTitle = radarrMovieTitle

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
            fatalError("Bazarr UI fixture server did not bind a port.")
        }
        return "http://127.0.0.1:\(port.rawValue)"
    }

    var requests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    func receivedTrackedMovieRequest(apiKey: String) -> Bool {
        requests.contains { request in
            request.method == "GET"
                && request.path == "/api/movies"
                && request.headers["x-api-key"] == apiKey
                && Self.queryValues(named: "radarrid[]", in: request.rawQuery).contains(String(radarrMovieID))
        }
    }

    func stop() {
        listener.cancel()
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

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
                lock.lock()
                recordedRequests.append(request)
                lock.unlock()

                connection.send(
                    content: Self.httpResponse(body: responseBody(for: request)),
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { _ in connection.cancel() }
                )
            } else if error != nil || isComplete {
                connection.cancel()
            } else {
                receive(on: connection, buffer: next)
            }
        }
    }

    // MARK: - Bazarr routes

    private func responseBody(for request: RecordedRequest) -> String {
        switch (request.method, request.path) {
        case ("GET", "/api/system/status"):
            // BazarrStatusResponse accepts the service's wrapped `data` shape.
            return #"{"data":{"bazarr_version":"1.5.0","package_version":"fixture"}}"#
        case ("GET", "/api/system/languages/profiles"):
            return #"""
            {"data":[{"profileId":\#(Self.languageProfileID),"name":"\#(Self.languageProfileName)","cutoff":null,"items":"[]","mustContain":[],"mustNotContain":[],"originalFormat":null,"tag":null}]}
            """#
        case ("GET", "/api/system/languages"):
            return #"{"data":[{"name":"English","code2":"en","code3":"eng","enabled":true}]}"#
        case ("GET", "/api/movies"):
            return moviesPageJSON()
        case ("GET", "/api/series"):
            return #"{"data":[],"total":0}"#
        default:
            // Array-style Bazarr endpoints decode this wrapped empty collection.
            return #"{"data":[]}"#
        }
    }

    /// Matches BazarrMovie's production CodingKeys, including a real assigned
    /// profile and one missing language. The card's tracked-state calculation must
    /// therefore render this as a missing subtitle rather than infer state from
    /// Radarr's embedded media info.
    private func moviesPageJSON() -> String {
        #"""
        {"data":[{"radarrId":\#(radarrMovieID),"title":"\#(radarrMovieTitle)","year":"2024","overview":"Fixture Bazarr state for a Radarr movie detail.","poster":null,"fanart":null,"audio_language":[],"monitored":true,"profileId":\#(Self.languageProfileID),"subtitles":[],"missing_subtitles":[{"name":"\#(Self.missingLanguageName)","code2":"en","code3":"eng","forced":false,"hi":false}],"tags":[],"alternativeTitles":[],"sceneName":null}],"total":1}
        """#
    }

    // MARK: - HTTP parsing

    private static func parseRequest(from data: Data) -> RecordedRequest? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: data[data.startIndex..<separator.lowerBound], encoding: .utf8) else {
            return nil
        }

        var lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        lines.removeFirst()
        let components = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard components.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<separator]).lowercased()
            headers[name] = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        }

        let target = String(components[1])
        let targetParts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        return RecordedRequest(
            method: String(components[0]),
            path: String(targetParts.first ?? ""),
            rawQuery: targetParts.count > 1 ? String(targetParts[1]) : "",
            headers: headers
        )
    }

    private static func queryValues(named name: String, in rawQuery: String) -> [String] {
        URLComponents(string: "http://127.0.0.1/?\(rawQuery)")?.queryItems?
            .filter { $0.name == name }
            .compactMap(\.value) ?? []
    }

    private static func httpResponse(body: String) -> Data {
        let bytes = Data(body.utf8)
        let headers = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        return Data(headers.utf8) + bytes
    }
}
