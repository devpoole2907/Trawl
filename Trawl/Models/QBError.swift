import Foundation

enum QBError: LocalizedError, Sendable {
    case authFailed
    case networkError(String)
    case invalidResponse
    case decodingError(String)
    case serverError(statusCode: Int, message: String?)
    case noServerConfigured
    case connectionTestFailed
    /// A 2xx answer that is an HTML page - a sign-in proxy, or an address that
    /// reaches some other web app. qBittorrent's API never answers with HTML.
    case webPage

    var errorDescription: String? {
        switch self {
        case .authFailed:
            "Authentication failed. Check your credentials."
        case .networkError(let message):
            "Network error: \(message)"
        case .invalidResponse:
            "Invalid response from server."
        case .decodingError(let message):
            "Failed to parse server response: \(message)"
        case .serverError(let code, let msg):
            "Server error (\(code)): \(msg ?? "Unknown")"
        case .noServerConfigured:
            "No server configured. Add a server in Settings."
        case .connectionTestFailed:
            "Could not connect to server. Check the URL and ensure qBittorrent is running."
        case .webPage:
            "The server answered with a web page, not qBittorrent's API. Check the address, or whether a sign-in page sits in front of it."
        }
    }
}
