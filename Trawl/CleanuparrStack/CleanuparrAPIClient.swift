import Foundation

/// Read-only client limited to Cleanuparr's documented Stats and Health APIs.
actor CleanuparrAPIClient {
    nonisolated var baseURL: String { transport.baseURL }

    private let transport: HTTPTransport

    init(baseURL: String, apiKey: String, allowsUntrustedTLS: Bool = false) {
        let mapper = HTTPErrorMapper(
            badURL: { CleanuparrAPIError.badURL },
            transport: { error in
                if let urlError = error as? URLError { return CleanuparrAPIError.transport(urlError) }
                return CleanuparrAPIError.transport(URLError(.unknown))
            },
            unauthorized: { CleanuparrAPIError.unauthorized },
            http: { status, body in CleanuparrAPIError.http(status: status, body: body) },
            decode: { error in CleanuparrAPIError.decode(reason: String(describing: error)) },
            invalidResponse: { CleanuparrAPIError.invalidResponse },
            unauthorizedStatusCodes: [401, 403]
        )

        transport = HTTPTransport(
            baseURL: baseURL,
            auth: .staticHeader(name: "X-Api-Key", value: apiKey),
            allowsUntrustedTLS: allowsUntrustedTLS,
            errorMapper: mapper
        )
    }

    func getStats(hours: Int = 168, includeDryRun: Bool = false) async throws -> CleanuparrStats {
        try await transport.get(
            "/api/v2/stats",
            queryItems: [
                URLQueryItem(name: "hours", value: String(min(max(hours, 1), 8_760))),
                URLQueryItem(name: "includeDryRun", value: includeDryRun ? "true" : "false")
            ]
        )
    }

    func isAlive() async throws -> Bool {
        do {
            try await transport.getVoid("/health")
            return true
        } catch CleanuparrAPIError.http(let status, _) where status == 503 {
            return false
        }
    }

    func isReady() async throws -> Bool {
        do {
            try await transport.getVoid("/health/ready")
            return true
        } catch CleanuparrAPIError.http(let status, _) where status == 503 {
            return false
        }
    }
}
