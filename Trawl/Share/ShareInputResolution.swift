import Foundation

/// Pure decision-making for the share extension's input handling.
///
/// This file is deliberately Foundation-only. It sits in `Share/` but, unlike
/// `ShareViewController.swift` and `ShareAddTorrentView.swift`, it is in no
/// target's `membershipExceptions`, so every target compiles it — including
/// TrawlMac and TrawlWidgets. Importing UIKit or SwiftUI here breaks the macOS
/// build. It also means `TrawlTests` can reach these types via `@testable
/// import Trawl`, which is the whole point: the rules below used to be buried
/// in `NSItemProvider` callbacks where nothing could test them.

// MARK: - Resolution

/// Which of the two file-bearing provider branches produced a file URL.
///
/// The distinction matters after the file is read: the NZB branch asked for a
/// specific type and a non-NZB filename there is a dead end, whereas the
/// torrent branch's UTType falls back to `.data`, so an NZB-named file landing
/// there is still an NZB.
nonisolated enum ShareFileBranch: Sendable, Equatable {
    case nzb
    case torrent
}

/// What a single `NSItemProvider.loadItem` callback resolved to.
///
/// Every `(loaded, error)` pair a provider can hand back maps onto exactly one
/// of these — including the pairs that used to fall through the old code's
/// guards and return without ending the extension request.
nonisolated enum ShareInputResolution: Sendable, Equatable {
    /// A magnet link, ready to hand to the share sheet.
    case magnetLink(String)
    /// An http(s) link to an NZB, ready to hand to the share sheet.
    case nzbLink(String)
    /// A file URL that still has to be read off disk.
    case fileToRead(URL, branch: ShareFileBranch)
    /// Nothing this extension can act on. Not an error — just not for us.
    case nothingUsable
    /// The provider itself failed. The message is the provider's own.
    case providerFailed(message: String)

    /// The terminal decision this resolution implies, or `nil` when the flow
    /// carries on (present the sheet, or read a file first).
    ///
    /// Keeping the mapping here rather than inside the view controller's switch
    /// is what makes "every provider outcome ends the request exactly once"
    /// something a test can actually assert.
    var termination: ShareTermination? {
        switch self {
        case .magnetLink, .nzbLink, .fileToRead:
            return nil
        case .nothingUsable:
            return .complete
        case .providerFailed(let message):
            return .cancel(message: message)
        }
    }
}

/// What a file turned out to be once its name was known.
nonisolated enum ShareFileClassification: Sendable, Equatable {
    case nzb
    case torrent
    /// Read fine, but not something the sheet can take.
    case unusable
}

// MARK: - Resolver

/// The rules that decide what shared input means. All pure, all total: every
/// function returns a resolution for every input, so no caller can accidentally
/// fall off the end without a decision.
nonisolated enum ShareInputResolver {

    // MARK: Providers

    /// The URL branch. Magnet links only — a magnet's scheme is "magnet", and
    /// arbitrary shared web URLs must not be treated as torrents. The one
    /// exception is an http(s) link ending in `.nzb`: that is the realistic way
    /// an NZB URL reaches an app, because indexers publish those and no iOS app
    /// emits an `nzb:` scheme, so none is registered.
    static func resolveURL(loaded: Any?, error: (any Error)?) -> ShareInputResolution {
        if let failure = providerFailure(error) { return failure }
        guard let url = loaded as? URL else { return .nothingUsable }

        if isNZBFileName(url.lastPathComponent),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return .nzbLink(url.absoluteString)
        }

        guard url.scheme?.lowercased() == "magnet" else { return .nothingUsable }
        return .magnetLink(url.absoluteString)
    }

    /// The `.nzb` file branch. Advertising a type is only a promise: the
    /// provider can still fail, or hand back raw `Data` instead of a file URL.
    static func resolveNZBFile(loaded: Any?, error: (any Error)?) -> ShareInputResolution {
        resolveFile(loaded: loaded, error: error, branch: .nzb)
    }

    /// The `.torrent` file branch, with the same two failure shapes.
    static func resolveTorrentFile(loaded: Any?, error: (any Error)?) -> ShareInputResolution {
        resolveFile(loaded: loaded, error: error, branch: .torrent)
    }

    /// The plain-text branch, for magnet links pasted as text. Text that is not
    /// a magnet link is nothing to act on, but it is still a decision — the old
    /// code had no `else` here at all and simply stranded the sheet.
    static func resolvePlainText(loaded: Any?, error: (any Error)?) -> ShareInputResolution {
        if let failure = providerFailure(error) { return failure }
        guard let text = loaded as? String,
              text.lowercased().hasPrefix("magnet:") else { return .nothingUsable }
        return .magnetLink(text)
    }

    // MARK: Files

    /// Settles what a successfully-read file actually is, given which branch
    /// asked for it.
    static func classify(fileName: String, advertisedAs branch: ShareFileBranch) -> ShareFileClassification {
        switch branch {
        case .nzb:
            return isNZBFileName(fileName) ? .nzb : .unusable
        case .torrent:
            // Some hosts describe an NZB only as generic data, which the
            // torrent branch's `?? .data` fallback matches. The name settles it.
            return isNZBFileName(fileName) ? .nzb : .torrent
        }
    }

    /// Mirrors `AddTorrentSheet.isNZBFileName` — SABnzbd also serves gzipped NZBs.
    static func isNZBFileName(_ fileName: String) -> Bool {
        let lowercased = fileName.lowercased()
        return lowercased.hasSuffix(".nzb") || lowercased.hasSuffix(".nzb.gz")
    }

    // MARK: Shared

    private static func resolveFile(
        loaded: Any?,
        error: (any Error)?,
        branch: ShareFileBranch
    ) -> ShareInputResolution {
        if let failure = providerFailure(error) { return failure }
        guard let url = loaded as? URL else { return .nothingUsable }
        return .fileToRead(url, branch: branch)
    }

    /// Flattens `any Error` to a message at the point the provider hands it
    /// over, so nothing but `Sendable` values cross onto the main actor.
    private static func providerFailure(_ error: (any Error)?) -> ShareInputResolution? {
        guard let error else { return nil }
        return .providerFailed(message: error.localizedDescription)
    }
}

// MARK: - Termination

/// How the extension request should end.
nonisolated enum ShareTermination: Sendable, Equatable {
    /// Complete the request. Used for success and for input that simply isn't
    /// actionable — which is what the URL path has always done.
    case complete
    /// Cancel the request so the host surfaces the provider's own message.
    case cancel(message: String)
}

/// A one-shot gate over ending the extension request.
///
/// `NSItemProvider` makes no promise that a completion handler fires only once,
/// and a single extension item can hold several providers that all resolve, so
/// the request has to be end-able exactly once however many times we get there
/// — a second `completeRequest` is a programmer error as far as UIKit is
/// concerned. The first claim hands back the termination to perform; every
/// claim after that hands back `nil`.
///
/// Not internally synchronised: it is a value the view controller owns on the
/// main actor, which is also the only place `NSExtensionContext` may be used.
nonisolated struct ShareTerminationGate: Sendable {
    private(set) var hasFinished = false

    init() {}

    mutating func claim(_ termination: ShareTermination) -> ShareTermination? {
        guard !hasFinished else { return nil }
        hasFinished = true
        return termination
    }
}
