import Foundation

enum ServerURLValidationError: LocalizedError {
    case empty
    case invalidFormat
    case unsupportedScheme
    case missingHost
    case unexpectedPath
    case unexpectedQuery

    var errorDescription: String? {
        switch self {
        case .empty:
            "Server URL is required."
        case .invalidFormat:
            "Enter a valid server URL, such as http://192.168.1.100:8080."
        case .unsupportedScheme:
            "Server URL must start with http:// or https://."
        case .missingHost:
            "Server URL must include a hostname or IP address."
        case .unexpectedPath:
            "Enter the server address only, without any trailing path such as /api or /webui."
        case .unexpectedQuery:
            "Server URL can't include query parameters or fragments."
        }
    }
}

enum ServerURLValidator {
    static func normalizedURLString(from rawValue: String, defaultScheme: String = "http") throws -> String {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            throw ServerURLValidationError.empty
        }

        let valueWithScheme: String
        if trimmedValue.contains("://") {
            valueWithScheme = trimmedValue
        } else {
            valueWithScheme = "\(defaultScheme)://\(trimmedValue)"
        }

        guard var components = URLComponents(string: valueWithScheme) else {
            throw ServerURLValidationError.invalidFormat
        }

        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw ServerURLValidationError.unsupportedScheme
        }

        guard let host = components.host, !host.isEmpty else {
            throw ServerURLValidationError.missingHost
        }

        if let path = components.percentEncodedPath.removingPercentEncoding, !path.isEmpty, path != "/" {
            throw ServerURLValidationError.unexpectedPath
        }

        guard components.query == nil, components.fragment == nil else {
            throw ServerURLValidationError.unexpectedQuery
        }

        components.scheme = scheme
        components.host = host
        components.path = ""
        components.query = nil
        components.fragment = nil

        guard let normalizedURL = components.url else {
            throw ServerURLValidationError.invalidFormat
        }

        return normalizedURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
