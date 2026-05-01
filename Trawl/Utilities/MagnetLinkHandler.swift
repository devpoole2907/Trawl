#if os(macOS)
import AppKit
import Foundation

enum MagnetLinkHandler {
    private static let scheme = "magnet"

    static var isDefault: Bool {
        guard let magnetURL = URL(string: "\(scheme):?xt=urn:btih:") else { return false }
        guard let defaultAppURL = NSWorkspace.shared.urlForApplication(toOpen: magnetURL) else { return false }

        return normalizedURL(defaultAppURL) == normalizedURL(Bundle.main.bundleURL)
    }

    @MainActor
    static func setAsDefault(completion: ((Result<Bool, any Error>) -> Void)? = nil) {
        NSWorkspace.shared.setDefaultApplication(
            at: Bundle.main.bundleURL,
            toOpenURLsWithScheme: scheme
        ) { error in
            Task { @MainActor in
                if let error {
                    completion?(.failure(error))
                } else {
                    completion?(.success(isDefault))
                }
            }
        }
    }

    private static func normalizedURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
#endif
