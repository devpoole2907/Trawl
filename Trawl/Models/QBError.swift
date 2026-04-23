import Foundation

enum QBError: LocalizedError, Sendable {
    case authFailed
    case networkError(String)
    case invalidResponse
    case decodingError(String)
    case serverError(statusCode: Int, message: String?)
    case noServerConfigured
    case connectionTestFailed

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
        }
    }
}
