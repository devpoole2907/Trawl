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

    /// Async rather than completion-handler based: AppKit calls back on an arbitrary
    /// thread, and hopping to the main actor from there meant sending a caller's
    /// closure across isolation domains - which callers do capture view state in.
    @MainActor
    static func setAsDefault() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            NSWorkspace.shared.setDefaultApplication(
                at: Bundle.main.bundleURL,
                toOpenURLsWithScheme: scheme
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func normalizedURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
#endif
