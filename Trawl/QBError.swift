import Foundation

enum QBError: LocalizedError, Sendable {
    case authFailed
    case networkError(Error)
    case invalidResponse
    case decodingError(Error)
    case serverError(statusCode: Int, message: String?)
    case noServerConfigured
    case connectionTestFailed

    var errorDescription: String? {
        switch self {
        case .authFailed:
            "Authentication failed. Check your credentials."
        case .networkError(let error):
            "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            "Invalid response from server."
        case .decodingError(let error):
            "Failed to parse server response: \(error.localizedDescription)"
        case .serverError(let code, let msg):
            "Server error (\(code)): \(msg ?? "Unknown")"
        case .noServerConfigured:
            "No server configured. Add a server in Settings."
        case .connectionTestFailed:
            "Could not connect to server. Check the URL and ensure qBittorrent is running."
        }
    }
}
