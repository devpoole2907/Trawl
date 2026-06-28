import AppIntents
import Foundation

/// User-friendly errors surfaced by the *arr App Intents.
///
/// Conforms to `CustomLocalizedStringResourceConvertible` so Siri / Shortcuts present the
/// message directly. Messages never include API keys or full service URLs.
nonisolated enum ArrIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case noServiceConfigured(String)
    case serviceSelectionRequired(String)
    case missingAPIKey(String)
    case connectionFailed(String)
    case noRootFolders
    case noQualityProfiles
    case itemAlreadyExists(String)
    case noResults(String)
    case unsupportedServiceType
    case invalidEntityIdentifier
    case requestFailed(String)

    /// Plain-text message, also reused when bridging into dialogs.
    var message: String {
        switch self {
        case .noServiceConfigured(let kind):
            return "No \(kind) is configured in Trawl. Add one in Trawl's settings first."
        case .serviceSelectionRequired(let kind):
            return "You have more than one \(kind). Choose which one to use."
        case .missingAPIKey(let name):
            return "Trawl couldn't find the API key for \(name). Re-enter it in Trawl's settings."
        case .connectionFailed(let name):
            return "Couldn't connect to \(name). Check that it's running and reachable."
        case .noRootFolders:
            return "That service has no root folders configured. Add one in its web settings first."
        case .noQualityProfiles:
            return "That service has no quality profiles configured."
        case .itemAlreadyExists(let title):
            return "\(title) is already in your library."
        case .noResults(let term):
            return term.isEmpty ? "No results found." : "No results found for \(term)."
        case .unsupportedServiceType:
            return "That action isn't supported for the selected service."
        case .invalidEntityIdentifier:
            return "That item is no longer available. Try searching again."
        case .requestFailed(let detail):
            return detail.isEmpty ? "The request failed." : detail
        }
    }

    var localizedStringResource: LocalizedStringResource {
        LocalizedStringResource(stringLiteral: message)
    }
}

/// Compact JSON+base64 codec used to make transient search-result entities fully
/// self-describing through their identifier, so they survive Shortcuts' cross-process
/// hand-off without needing a live network lookup to rehydrate.
nonisolated enum ArrIDCodec {
    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value).base64EncodedString()
    }

    static func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        guard let data = Data(base64Encoded: string) else {
            throw ArrIntentError.invalidEntityIdentifier
        }
        return try JSONDecoder().decode(type, from: data)
    }
}
