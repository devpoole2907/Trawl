import Foundation

enum SABnzbdAPIError: Error, LocalizedError, Sendable {
    case badURL
    case transport(URLError)
    case unauthorized
    case insufficientAPIKey
    case api(message: String)
    case http(status: Int, body: String?)
    case decode(reason: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .badURL:
            "The SABnzbd URL is not valid."
        case .transport(let error):
            "Couldn't reach SABnzbd: \(error.localizedDescription)"
        case .unauthorized:
            "The SABnzbd API key is missing or no longer valid."
        case .insufficientAPIKey:
            "Trawl needs the full SABnzbd API key, not the add-only NZB key."
        case .api(let message):
            "SABnzbd returned an error: \(message)"
        case .http(let status, let body):
            if let message = Self.message(from: body), !message.isEmpty {
                "SABnzbd returned \(status): \(message)"
            } else {
                "SABnzbd returned status \(status)."
            }
        case .decode(let reason):
            "Couldn't read the SABnzbd response: \(reason)"
        case .invalidResponse:
            "SABnzbd returned an unexpected response."
        }
    }

    private static func message(from body: String?) -> String? {
        guard let body, !body.isEmpty else { return nil }
        guard
            let data = body.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let error = object["error"] as? String { return error }
        if let message = object["message"] as? String { return message }
        return nil
    }
}
