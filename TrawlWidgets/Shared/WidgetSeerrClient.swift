import Foundation

// MARK: - Lightweight Seerr DTOs for widgets

nonisolated struct WidgetSeerrPageInfo: Codable, Sendable {
    let results: Int?
}

nonisolated struct WidgetSeerrPagedResponse<Element>: Codable, Sendable where Element: Codable & Sendable {
    let pageInfo: WidgetSeerrPageInfo
    let results: [Element]
}

nonisolated struct WidgetSeerrRequestCount: Codable, Sendable {
    let pending: Int?
}

typealias WidgetSeerrRequestListResponse = WidgetSeerrPagedResponse<WidgetSeerrMediaRequest>
typealias WidgetSeerrIssueListResponse = WidgetSeerrPagedResponse<WidgetSeerrIssue>

nonisolated struct WidgetSeerrMediaRequest: Codable, Identifiable, Sendable {
    let id: Int
    let media: WidgetSeerrRequestMedia?
    let createdAt: String?
    let requestedBy: WidgetSeerrUser?
    let is4k: Bool?
}

nonisolated struct WidgetSeerrRequestMedia: Codable, Sendable {
    let mediaType: String?
    let title: String?
    let name: String?
    let originalTitle: String?
    let originalName: String?

    var displayTitle: String {
        title ?? name ?? originalTitle ?? originalName ?? "Unknown Media"
    }

    var typeLabel: String {
        switch mediaType {
        case "movie": "Movie"
        case "tv": "Series"
        case let value?: value.capitalized
        case nil: "Media"
        }
    }
}

nonisolated struct WidgetSeerrIssue: Codable, Identifiable, Sendable {
    let id: Int
    let issueType: Int?
    let media: WidgetSeerrIssueMedia?
    let createdBy: WidgetSeerrUser?
    let createdAt: String?

    var issueKindLabel: String {
        switch issueType {
        case 1: "Video"
        case 2: "Audio"
        case 3: "Subtitle"
        case 4: "Other"
        default: "Issue"
        }
    }
}

nonisolated struct WidgetSeerrIssueMedia: Codable, Sendable {
    let title: String?
    let originalTitle: String?
    let name: String?
    let originalName: String?

    var displayTitle: String {
        title ?? name ?? originalTitle ?? originalName ?? "Unknown Media"
    }
}

nonisolated struct WidgetSeerrUser: Codable, Identifiable, Sendable {
    let id: Int
    let displayNameValue: String?
    let jellyfinUsername: String?
    let discordUsername: String?
    let email: String?
    let username: String?
    let plexUsername: String?

    var displayName: String {
        displayNameValue ??
        jellyfinUsername ??
        username ??
        plexUsername ??
        discordUsername ??
        fallbackNameFromEmail ??
        "User"
    }

    private var fallbackNameFromEmail: String? {
        guard let email, let localPart = email.split(separator: "@").first, !localPart.isEmpty else {
            return nil
        }
        return localPart
            .split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
            .map { chunk in
                let value = String(chunk)
                return value.prefix(1).uppercased() + value.dropFirst()
            }
            .joined(separator: " ")
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayNameValue = "displayName"
        case jellyfinUsername
        case discordUsername
        case email
        case username
        case plexUsername
    }
}

// MARK: - Lightweight Seerr HTTP client

enum WidgetSeerrAPIError: LocalizedError {
    case badURL
    case transport(URLError)
    case unauthorized
    case http(status: Int, body: String?)
    case decode(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .badURL: "Invalid Seerr URL."
        case .transport(let error): error.localizedDescription
        case .unauthorized: "Seerr session expired."
        case .http(let status, let body): body?.isEmpty == false ? "Seerr HTTP \(status): \(body!)" : "Seerr HTTP \(status)."
        case .decode(let reason): "Could not decode Seerr response: \(reason)"
        case .invalidResponse: "Invalid Seerr response."
        }
    }
}

actor WidgetSeerrAPIClient {
    nonisolated var baseURL: String { transport.baseURL }
    private let transport: HTTPTransport
    private var onCookieUpdate: (@Sendable (String) -> Void)?

    init(baseURL: String, sessionCookie: String, allowsUntrustedTLS: Bool = false) {
        let mapper = HTTPErrorMapper(
            badURL: { WidgetSeerrAPIError.badURL },
            transport: { error in
                if let urlError = error as? URLError { return WidgetSeerrAPIError.transport(urlError) }
                return WidgetSeerrAPIError.transport(URLError(.unknown))
            },
            unauthorized: { WidgetSeerrAPIError.unauthorized },
            http: { code, body in WidgetSeerrAPIError.http(status: code, body: body) },
            decode: { error in WidgetSeerrAPIError.decode(String(describing: error)) },
            invalidResponse: { WidgetSeerrAPIError.invalidResponse },
            unauthorizedStatusCodes: [401, 403]
        )

        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 30

        self.transport = HTTPTransport(
            baseURL: baseURL,
            auth: .mutable(name: "Cookie", format: { value in
                guard let value, !value.isEmpty else { return nil }
                return "connect.sid=\(value)"
            }),
            initialMutableAuthValue: sessionCookie,
            allowsUntrustedTLS: allowsUntrustedTLS,
            sessionConfiguration: config,
            errorMapper: mapper
        )
    }

    func setCookieUpdateHandler(_ handler: @escaping @Sendable (String) -> Void) async {
        self.onCookieUpdate = handler
        await transport.setResponseObserver { [weak self] response in
            guard let updated = Self.extractSessionCookie(from: response), !updated.isEmpty else { return }
            Task { [weak self] in
                await self?.handleRollingCookie(updated)
            }
        }
    }

    func getRequestCount() async throws -> WidgetSeerrRequestCount {
        try await get("/api/v1/request/count")
    }

    func getRequests(take: Int = 20, skip: Int = 0, filter: String = "pending", sort: String = "added", sortDirection: String = "desc") async throws -> WidgetSeerrRequestListResponse {
        try await get("/api/v1/request", params: [
            "take": String(take),
            "skip": String(skip),
            "filter": filter,
            "sort": sort,
            "sortDirection": sortDirection,
            "mediaType": "all"
        ])
    }

    func getIssues(take: Int = 20, skip: Int = 0, sort: String = "added", filter: String = "open") async throws -> WidgetSeerrIssueListResponse {
        try await get("/api/v1/issue", params: [
            "take": String(take),
            "skip": String(skip),
            "sort": sort,
            "filter": filter
        ])
    }

    private func get<T: Decodable>(_ path: String, params: [String: String] = [:]) async throws -> T {
        try await transport.get(path, queryItems: params.map { URLQueryItem(name: $0.key, value: $0.value) })
    }

    private func handleRollingCookie(_ updated: String) async {
        let current = await transport.currentMutableAuthValue()
        guard current != updated else { return }
        await transport.setMutableAuthValue(updated)
        onCookieUpdate?(updated)
    }

    private nonisolated static func extractSessionCookie(from response: HTTPURLResponse) -> String? {
        guard let url = response.url else { return nil }

        for headerValue in setCookieHeaderValues(from: response) {
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": headerValue], for: url)
            if let value = cookies.first(where: { $0.name == "connect.sid" })?.value {
                return value
            }
            if let value = sessionCookieValue(fromSetCookieHeader: headerValue) {
                return value
            }
        }
        return nil
    }

    private nonisolated static func setCookieHeaderValues(from response: HTTPURLResponse) -> [String] {
        var values: [String] = []
        for (rawKey, rawValue) in response.allHeaderFields {
            guard let key = rawKey as? String,
                  key.caseInsensitiveCompare("Set-Cookie") == .orderedSame
            else { continue }
            appendSetCookieHeaderValues(rawValue, to: &values)
        }

        if values.isEmpty, let fallback = response.value(forHTTPHeaderField: "Set-Cookie") {
            appendSetCookieHeader(fallback, to: &values)
        }
        return values
    }

    private nonisolated static func appendSetCookieHeaderValues(_ rawValue: Any, to values: inout [String]) {
        if let value = rawValue as? String {
            appendSetCookieHeader(value, to: &values)
        } else if let valueList = rawValue as? [String] {
            valueList.forEach { appendSetCookieHeader($0, to: &values) }
        } else if let valueList = rawValue as? NSArray {
            valueList.compactMap { $0 as? String }.forEach { appendSetCookieHeader($0, to: &values) }
        }
    }

    private nonisolated static func appendSetCookieHeader(_ value: String, to values: inout [String]) {
        let lines = value
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if lines.isEmpty {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedValue.isEmpty {
                values.append(trimmedValue)
            }
        } else {
            values.append(contentsOf: lines)
        }
    }

    private nonisolated static func sessionCookieValue(fromSetCookieHeader header: String) -> String? {
        let marker = "connect.sid="
        var searchRange = header.startIndex..<header.endIndex
        while let markerRange = header.range(of: marker, options: [.caseInsensitive], range: searchRange) {
            if isCookieBoundary(before: markerRange.lowerBound, in: header) {
                let valueStart = markerRange.upperBound
                let valueEnd = header[valueStart...].firstIndex { character in
                    character == ";" || character == "," || character.isNewline
                } ?? header.endIndex
                let value = header[valueStart..<valueEnd].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    return value
                }
            }
            searchRange = markerRange.upperBound..<header.endIndex
        }
        return nil
    }

    private nonisolated static func isCookieBoundary(before index: String.Index, in header: String) -> Bool {
        guard index > header.startIndex else { return true }
        let previous = header[..<index].last { !$0.isWhitespace }
        return previous == ","
    }
}
