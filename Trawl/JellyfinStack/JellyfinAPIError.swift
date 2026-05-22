import Foundation

enum JellyfinAPIError: Error, LocalizedError {
    case badURL
    case transport(URLError)
    case unauthorized
    case http(status: Int, body: String?)
    case decode(reason: String)
    case invalidResponse
    case notAdmin

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "The Jellyfin URL is not valid."
        case .transport(let urlError):
            return "Couldn't reach Jellyfin: \(urlError.localizedDescription)"
        case .unauthorized:
            return "Your Jellyfin credentials are no longer valid. Please sign in again."
        case .http(let status, let body):
            if let message = Self.extractMessage(from: body), !message.isEmpty {
                return "Jellyfin returned \(status): \(message)"
            }
            return "Jellyfin returned status \(status)."
        case .decode(let reason):
            return "Couldn't read Jellyfin response: \(reason)"
        case .invalidResponse:
            return "Jellyfin returned an unexpected response."
        case .notAdmin:
            return "An administrator account is required to manage Jellyfin from Trawl."
        }
    }

    private static func extractMessage(from body: String?) -> String? {
        guard
            let body,
            let data = body.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        if let message = object["Message"] as? String { return message }
        if let message = object["message"] as? String { return message }
        if let error = object["error"] as? String { return error }
        return nil
    }
}
