import Foundation

// MARK: - Auth

/// Auth strategy. Static values are baked in at init; mutable values
/// (Seerr session cookies, Jellyfin access tokens) are stored on the transport
/// itself and combined with the format closure when each request is built.
enum HTTPAuth: Sendable {
    /// Single static header, e.g. `X-Api-Key: <key>`.
    case staticHeader(name: String, value: String)
    /// Header whose value is computed from a mutable token managed by the transport.
    /// The format closure wraps the token (or nil) into the final header string,
    /// or returns nil to omit the header entirely.
    case mutable(name: String, format: @Sendable (String?) -> String?)
    case none
}

// MARK: - Error mapping

/// Per-service error mapping. The transport translates raw failures into the
/// caller's domain error type via these closures so each service-specific
/// client keeps its own error vocabulary (`ArrError`, `SeerrAPIError`, `JellyfinAPIError`).
struct HTTPErrorMapper: Sendable {
    let badURL: @Sendable () -> any Error
    let transport: @Sendable (Error) -> any Error
    let unauthorized: @Sendable () -> any Error
    let http: @Sendable (Int, String?) -> any Error
    let decode: @Sendable (Error) -> any Error
    let invalidResponse: @Sendable () -> any Error
    /// Status codes that should be mapped to `unauthorized()`. Arr maps 401 only;
    /// Seerr/Jellyfin map both 401 and 403.
    let unauthorizedStatusCodes: Set<Int>
}

// MARK: - Diagnostics

/// Optional hook for verbose logging on specific request paths. Used by ArrAPIClient
/// to log /release endpoint failures for interactive search debugging.
struct HTTPDiagnostics: Sendable {
    let shouldLog: @Sendable (_ path: String) -> Bool
    let networkError: @Sendable (_ path: String, _ urlString: String, _ error: Error) -> Void
    let httpError: @Sendable (_ path: String, _ urlString: String, _ statusCode: Int, _ body: Data?) -> Void
    let decodingError: @Sendable (_ path: String, _ urlString: String, _ error: Error, _ body: Data?) -> Void
}

// MARK: - Transport

/// Shared HTTP infrastructure used by ArrAPIClient, SeerrAPIClient, and JellyfinAPIClient.
///
/// Owns the URLSession, the server-trust delegate, and any mutable auth state
/// (session cookies / access tokens). Service-specific clients delegate request
/// primitives here and provide their own endpoint methods on top.
actor HTTPTransport {
    nonisolated let baseURL: String
    private let session: URLSession
    private let trustPolicy: ServerTrustPolicy
    private let errorMapper: HTTPErrorMapper
    private let diagnostics: HTTPDiagnostics?

    private let authKind: HTTPAuth
    private var mutableAuthValue: String?
    private var responseObserver: (@Sendable (HTTPURLResponse) -> Void)?

    init(
        baseURL: String,
        auth: HTTPAuth,
        initialMutableAuthValue: String? = nil,
        allowsUntrustedTLS: Bool = false,
        sessionConfiguration: URLSessionConfiguration = .makeTrawlSecure(),
        errorMapper: HTTPErrorMapper,
        diagnostics: HTTPDiagnostics? = nil
    ) {
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasSuffix("/") { url = String(url.dropLast()) }
        self.baseURL = url
        self.authKind = auth
        self.mutableAuthValue = initialMutableAuthValue
        self.errorMapper = errorMapper
        self.diagnostics = diagnostics
        self.trustPolicy = ServerTrustPolicy(allowsUntrustedTLS: allowsUntrustedTLS)
        self.session = URLSession(configuration: sessionConfiguration, delegate: trustPolicy, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    // MARK: - Mutable auth

    func setMutableAuthValue(_ value: String?) { mutableAuthValue = value }
    func currentMutableAuthValue() -> String? { mutableAuthValue }

    /// Sets an observer invoked synchronously inside the transport on every
    /// response (success or HTTP error). Used by Seerr to capture rolling
    /// `connect.sid` cookies; the observer typically calls back into
    /// `setMutableAuthValue(_:)` on the same transport.
    func setResponseObserver(_ observer: (@Sendable (HTTPURLResponse) -> Void)?) {
        self.responseObserver = observer
    }

    // MARK: - Request builders

    private func applyAuth(to request: inout URLRequest) {
        switch authKind {
        case .none:
            return
        case .staticHeader(let name, let value):
            request.setValue(value, forHTTPHeaderField: name)
        case .mutable(let name, let format):
            if let header = format(mutableAuthValue) {
                request.setValue(header, forHTTPHeaderField: name)
            }
        }
    }

    func buildRequest(path: String, method: String, queryItems: [URLQueryItem] = []) throws -> URLRequest {
        guard var components = URLComponents(string: "\(baseURL)\(path)") else {
            throw errorMapper.badURL()
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw errorMapper.badURL()
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        applyAuth(to: &request)
        return request
    }

    // MARK: - Core perform

    /// Performs the request and returns the raw data + parsed HTTPURLResponse,
    /// after running the response observer. Does NOT validate the status code —
    /// callers that need raw access (Seerr login) get the unmodified response.
    func performRaw(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? "<unknown>"
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw errorMapper.invalidResponse()
            }
            responseObserver?(http)
            return (data, http)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch let nsError as NSError where nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            throw CancellationError()
        } catch {
            if let diagnostics, diagnostics.shouldLog(path) {
                diagnostics.networkError(
                    path,
                    request.url?.absoluteString ?? "\(baseURL)\(path)",
                    error
                )
            }
            throw errorMapper.transport(error)
        }
    }

    /// Validates the response status code, mapping 401/403 to unauthorized and
    /// non-2xx (excluding 3xx success) to the service's http error.
    private func validate(_ response: HTTPURLResponse, data: Data, path: String, urlString: String) throws {
        if errorMapper.unauthorizedStatusCodes.contains(response.statusCode) {
            throw errorMapper.unauthorized()
        }
        guard (200..<400).contains(response.statusCode) else {
            if let diagnostics, diagnostics.shouldLog(path) {
                diagnostics.httpError(path, urlString, response.statusCode, data)
            }
            throw errorMapper.http(response.statusCode, Self.bodyString(from: data))
        }
    }

    /// Performs a request that returns no body, validating the status code.
    func performVoid(_ request: URLRequest) async throws {
        let path = request.url?.path ?? "<unknown>"
        let urlString = request.url?.absoluteString ?? "\(baseURL)\(path)"
        let (data, response) = try await performRaw(request)
        try validate(response, data: data, path: path, urlString: urlString)
    }

    /// Performs a request and decodes the body as JSON.
    func perform<T: Decodable>(_ request: URLRequest) async throws -> sending T {
        let path = request.url?.path ?? "<unknown>"
        let urlString = request.url?.absoluteString ?? "\(baseURL)\(path)"
        let (data, response) = try await performRaw(request)
        try validate(response, data: data, path: path, urlString: urlString)
        do {
            return try Self.decodeResponse(T.self, from: data)
        } catch {
            if let diagnostics, diagnostics.shouldLog(path) {
                diagnostics.decodingError(path, urlString, error, data)
            }
            throw errorMapper.decode(error)
        }
    }

    /// Performs a request and returns the validated response body unchanged.
    func performData(_ request: URLRequest) async throws -> Data {
        let path = request.url?.path ?? "<unknown>"
        let urlString = request.url?.absoluteString ?? "\(baseURL)\(path)"
        let (data, response) = try await performRaw(request)
        try validate(response, data: data, path: path, urlString: urlString)
        return data
    }

    private nonisolated static func decodeResponse<T: Decodable>(_ type: sending T.Type, from data: Data) throws -> sending T {
        try JSONDecoder().decode(type, from: data)
    }

    private nonisolated static func bodyString(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - HTTP method conveniences

    func get<T: Decodable>(_ path: String, queryItems: [URLQueryItem] = []) async throws -> sending T {
        let request = try buildRequest(path: path, method: "GET", queryItems: queryItems)
        return try await perform(request)
    }

    func getData(_ path: String, queryItems: [URLQueryItem] = []) async throws -> Data {
        let request = try buildRequest(path: path, method: "GET", queryItems: queryItems)
        return try await performData(request)
    }

    func getVoid(_ path: String, queryItems: [URLQueryItem] = []) async throws {
        let request = try buildRequest(path: path, method: "GET", queryItems: queryItems)
        try await performVoid(request)
    }

    func postJSON<T: Decodable>(_ path: String, jsonBody: sending Any, queryItems: [URLQueryItem] = []) async throws -> sending T {
        var request = try buildRequest(path: path, method: "POST", queryItems: queryItems)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        return try await perform(request)
    }

    func postCodable<T: Decodable, B: Encodable>(_ path: String, body: sending B, queryItems: [URLQueryItem] = []) async throws -> sending T {
        var request = try buildRequest(path: path, method: "POST", queryItems: queryItems)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    func putCodable<T: Decodable, B: Encodable>(_ path: String, body: sending B, queryItems: [URLQueryItem] = []) async throws -> sending T {
        var request = try buildRequest(path: path, method: "PUT", queryItems: queryItems)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await perform(request)
    }

    func delete(_ path: String, queryItems: [URLQueryItem] = []) async throws {
        let request = try buildRequest(path: path, method: "DELETE", queryItems: queryItems)
        try await performVoid(request)
    }

    func deleteJSONBody(_ path: String, jsonBody: sending Any) async throws {
        var request = try buildRequest(path: path, method: "DELETE")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        try await performVoid(request)
    }

    func postVoidJSON(_ path: String, jsonBody: sending Any) async throws {
        var request = try buildRequest(path: path, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        try await performVoid(request)
    }

    func postVoid(_ path: String, queryItems: [URLQueryItem] = []) async throws {
        let request = try buildRequest(path: path, method: "POST", queryItems: queryItems)
        try await performVoid(request)
    }

    func patchVoid(_ path: String, queryItems: [URLQueryItem] = []) async throws {
        let request = try buildRequest(path: path, method: "PATCH", queryItems: queryItems)
        try await performVoid(request)
    }

    func postVoidCodable<B: Encodable>(_ path: String, body: sending B, queryItems: [URLQueryItem] = []) async throws {
        var request = try buildRequest(path: path, method: "POST", queryItems: queryItems)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        try await performVoid(request)
    }

    /// POST with a multipart/form-data body containing a single file field.
    func postMultipartVoid(_ path: String, fileData: Data, fieldName: String, filename: String, mimeType: String = "application/zip") async throws {
        let boundary = "TrawlBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var request = try buildRequest(path: path, method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        for string in [
            "--\(boundary)\r\n",
            "Content-Disposition: form-data; name=\"\(fieldName)\"; filename=\"\(filename)\"\r\n",
            "Content-Type: \(mimeType)\r\n\r\n"
        ] {
            if let d = string.data(using: .utf8) { body.append(d) }
        }
        body.append(fileData)
        if let closing = "\r\n--\(boundary)--\r\n".data(using: .utf8) { body.append(closing) }

        request.httpBody = body
        try await performVoid(request)
    }

    /// POST with a form-urlencoded body. Preserves repeated keys and empty-list
    /// sentinels because Bazarr's settings endpoint relies on that semantics.
    func postFormItems(_ path: String, formItems: [URLQueryItem]) async throws {
        var request = try buildRequest(path: path, method: "POST")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = formItems
        request.httpBody = components.query?.data(using: .utf8)
        try await performVoid(request)
    }
}
