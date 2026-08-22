import Foundation

actor AuthService {
    private let session: URLSession
    private let ownsSession: Bool
    private let trustPolicy: ServerTrustPolicy
    private var sid: String?
    private var cookieName: String?
    private var authTask: Task<Void, Error>?
    let serverProfileID: UUID

    /// - Parameter session: Transport used for the login round trip. Defaults to a
    ///   private cookie-less ephemeral session; inject one to drive login against a
    ///   stubbed transport.
    init(serverProfileID: UUID, allowsUntrustedTLS: Bool = false, session: URLSession? = nil) {
        self.serverProfileID = serverProfileID
        self.trustPolicy = ServerTrustPolicy(allowsUntrustedTLS: allowsUntrustedTLS)
        if let session {
            self.session = session
            self.ownsSession = false
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.httpCookieAcceptPolicy = .never
            self.session = URLSession(configuration: config, delegate: trustPolicy, delegateQueue: nil)
            self.ownsSession = true
        }
    }

    deinit {
        // An injected session belongs to its owner; only tear down one we created.
        if ownsSession {
            session.invalidateAndCancel()
        }
    }

    var isAuthenticated: Bool { sid != nil }

    /// Authenticate against qBittorrent and store the SID cookie.
    ///
    /// Concurrent calls are coalesced: if a login is already in flight (e.g. two
    /// requests both hit a 403 and trigger re-auth), later callers await the same
    /// task rather than returning early with no SID and proceeding on a stale cookie.
    func login(hostURL: String, username: String, password: String) async throws {
        if let authTask {
            try await authTask.value
            return
        }
        let task = Task { try await self.performLogin(hostURL: hostURL, username: username, password: password) }
        authTask = task
        defer { authTask = nil }
        try await task.value
    }

    private func performLogin(hostURL: String, username: String, password: String) async throws {
        guard let url = URL(string: "\(hostURL)/api/v2/auth/login") else {
            throw QBError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "username=\(URLEncoding.unreservedEncode(username))&password=\(URLEncoding.unreservedEncode(password))"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw QBError.invalidResponse
        }

        let bodyText = String(data: data, encoding: .utf8) ?? ""

        // qBittorrent v5.2.2+ returns 204 No Content; older versions return 200 with "Ok." body
        let isValidResponse = (httpResponse.statusCode == 204) ||
                              (httpResponse.statusCode == 200 && bodyText.contains("Ok."))

        guard isValidResponse else {
            throw QBError.authFailed
        }

        // Extract SID from Set-Cookie header
        if let setCookie = httpResponse.value(forHTTPHeaderField: "Set-Cookie") {
            let (name, value) = extractSessionCookie(from: setCookie)
            self.cookieName = name
            self.sid = value
        }

        guard sid != nil else {
            throw QBError.authFailed
        }
    }

    /// Attach the SID cookie to a URLRequest.
    func authorize(_ request: inout URLRequest) {
        if let sid, let cookieName {
            request.setValue("\(cookieName)=\(sid)", forHTTPHeaderField: "Cookie")
        }
    }

    /// Clear the active session.
    func logout() async {
        sid = nil
        cookieName = nil
        await session.reset()
    }

    // MARK: - Private

    /// Extracts the session cookie from Set-Cookie header.
    /// qBittorrent v5.2.2+ uses "QBT_SID_<port>", older versions use "SID".
    /// Returns (cookieName, cookieValue).
    private func extractSessionCookie(from setCookieHeader: String) -> (String?, String?) {
        // Set-Cookie: SID=<value>; ... (old format)
        // Set-Cookie: QBT_SID_8070=<value>; HttpOnly; SameSite=Lax; ... (new format)
        let components = setCookieHeader.components(separatedBy: ";")
        for component in components {
            let trimmed = component.trimmingCharacters(in: .whitespaces)

            // Check for new format: QBT_SID_*
            if trimmed.hasPrefix("QBT_SID_"), let eqIndex = trimmed.firstIndex(of: "=") {
                let name = String(trimmed[..<eqIndex])
                let value = String(trimmed[trimmed.index(after: eqIndex)...])
                return (name, value)
            }

            // Check for old format: SID
            if trimmed.hasPrefix("SID=") {
                let value = String(trimmed.dropFirst(4))
                return ("SID", value)
            }
        }
        return (nil, nil)
    }
}
