import Foundation

actor AuthService {
    private let session: URLSession
    private var sid: String?
    private var isAuthenticating = false
    let serverProfileID: UUID

    init(serverProfileID: UUID) {
        self.serverProfileID = serverProfileID
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        self.session = URLSession(configuration: config)
    }

    var isAuthenticated: Bool { sid != nil }

    /// Authenticate against qBittorrent and store the SID cookie.
    func login(hostURL: String, username: String, password: String) async throws {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }

        guard let url = URL(string: "\(hostURL)/api/v2/auth/login") else {
            throw QBError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "username=\(urlEncode(username))&password=\(urlEncode(password))"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw QBError.invalidResponse
        }

        let bodyText = String(data: data, encoding: .utf8) ?? ""

        guard httpResponse.statusCode == 200, bodyText.contains("Ok.") else {
            throw QBError.authFailed
        }

        // Extract SID from Set-Cookie header
        if let setCookie = httpResponse.value(forHTTPHeaderField: "Set-Cookie") {
            sid = extractSID(from: setCookie)
        }

        guard sid != nil else {
            throw QBError.authFailed
        }
    }

    /// Attach the SID cookie to a URLRequest.
    func authorize(_ request: inout URLRequest) {
        if let sid {
            request.setValue("SID=\(sid)", forHTTPHeaderField: "Cookie")
        }
    }

    /// Clear the active session.
    func logout() {
        sid = nil
    }

    // MARK: - Private

    private func extractSID(from setCookieHeader: String) -> String? {
        // Set-Cookie: SID=<value>; ...
        let components = setCookieHeader.components(separatedBy: ";")
        for component in components {
            let trimmed = component.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("SID=") {
                return String(trimmed.dropFirst(4))
            }
        }
        return nil
    }

    private func urlEncode(_ string: String) -> String {
        // Must encode &, =, + which are delimiters in application/x-www-form-urlencoded
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}
