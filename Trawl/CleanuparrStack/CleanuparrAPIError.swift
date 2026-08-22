import Foundation

enum CleanuparrAPIError: Error, LocalizedError, Sendable {
    case badURL
    case transport(URLError)
    case unauthorized
    case http(status: Int, body: String?)
    case decode(reason: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .badURL:
            "The Cleanuparr URL is not valid."
        case .transport(let error):
            "Couldn't reach Cleanuparr: \(error.localizedDescription)"
        case .unauthorized:
            "The Cleanuparr API key is missing or no longer valid."
        case .http(let status, let body):
            if let message = Self.message(from: body), !message.isEmpty {
                "Cleanuparr returned \(status): \(message)"
            } else {
                "Cleanuparr returned status \(status)."
            }
        case .decode(let reason):
            "Couldn't read the Cleanuparr response: \(reason)"
        case .invalidResponse:
            "Cleanuparr returned an unexpected response."
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
        if let title = object["title"] as? String { return title }
        return nil
    }
}
