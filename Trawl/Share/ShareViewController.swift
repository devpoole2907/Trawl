import UIKit
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// The UIKit half of the share extension: it picks a provider, hands the raw
/// callback pair to `ShareInputResolver`, and performs whatever that decides.
/// All of the actual rules - what counts as a magnet link, an NZB link, an NZB
/// filename, or a dead end, and whether the request may still be ended - live in
/// `ShareInputResolution.swift`, which is Foundation-only and testable.
@MainActor
final class ShareViewController: UIViewController {
    private var magnetURL: String?
    private var torrentFileData: Data?
    private var torrentFileName: String?
    private var nzbURL: String?
    private var nzbFileData: Data?
    private var nzbFileName: String?

    /// Guarantees the extension request ends exactly once, however many times a
    /// provider calls back or however many providers resolve.
    private var terminationGate = ShareTerminationGate()

    /// There is no system UTType for NZB, so the app declares `org.newzbin.nzb`
    /// in both Info.plists. Hosts that never saw the declaration hand the file
    /// over as plain XML instead, hence the fallback - the filename is what
    /// actually decides, matching `AddTorrentSheet`.
    nonisolated private static var nzbType: UTType { UTType("org.newzbin.nzb") ?? UTType(filenameExtension: "nzb") ?? .xml }

    override func viewDidLoad() {
        super.viewDidLoad()
        extractSharedContent()
    }

    private func extractSharedContent() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            finish(.complete)
            return
        }

        for item in extensionItems {
            guard let attachments = item.attachments else { continue }

            for provider in attachments {
                // URLs first (magnet links, plus http(s) links to an .nzb).
                // Don't treat arbitrary shared web URLs as torrents.
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    load(UTType.url.identifier, from: provider) {
                        ShareInputResolver.resolveURL(loaded: $0, error: $1)
                    }
                    return
                }

                // .nzb files. Tested before .torrent because that branch falls
                // back to `.data`, which would otherwise swallow an NZB.
                if provider.hasItemConformingToTypeIdentifier(Self.nzbType.identifier) {
                    load(Self.nzbType.identifier, from: provider) {
                        ShareInputResolver.resolveNZBFile(loaded: $0, error: $1)
                    }
                    return
                }

                // .torrent files
                let torrentType = UTType(filenameExtension: "torrent") ?? .data
                if provider.hasItemConformingToTypeIdentifier(torrentType.identifier) {
                    load(torrentType.identifier, from: provider) {
                        ShareInputResolver.resolveTorrentFile(loaded: $0, error: $1)
                    }
                    return
                }

                // Plain text (magnet links pasted as text)
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    load(UTType.plainText.identifier, from: provider) {
                        ShareInputResolver.resolvePlainText(loaded: $0, error: $1)
                    }
                    return
                }
            }
        }

        // Nothing usable found
        finish(.complete)
    }

    /// Loads one advertised type and applies whatever `resolve` makes of it.
    ///
    /// The resolution is computed inside the provider's own callback, on
    /// whatever thread that arrives on, so only a `Sendable` value crosses onto
    /// the main actor - never a bare `any Error`.
    private func load(
        _ typeIdentifier: String,
        from provider: NSItemProvider,
        using resolve: @escaping @Sendable (Any?, (any Error)?) -> ShareInputResolution
    ) {
        provider.loadItem(forTypeIdentifier: typeIdentifier) { [weak self] loaded, error in
            let resolution = resolve(loaded, error)
            Task { @MainActor [weak self] in self?.apply(resolution) }
        }
    }

    /// Performs a resolution. Every case either ends the request or moves the
    /// flow forward to something that will.
    private func apply(_ resolution: ShareInputResolution) {
        if let termination = resolution.termination {
            finish(termination)
            return
        }

        switch resolution {
        case .magnetLink(let magnet):
            magnetURL = magnet
            presentShareUI()

        case .nzbLink(let link):
            nzbURL = link
            presentShareUI()

        case .fileToRead(let url, let branch):
            readFile(at: url, advertisedAs: branch)

        case .nothingUsable, .providerFailed:
            // Unreachable: both carry a termination, handled above. Listed so
            // adding a case to the enum breaks this switch rather than silently
            // stranding the sheet again.
            finish(.complete)
        }
    }

    /// Reads a shared file off disk, then lets the resolver settle what it is.
    private func readFile(at url: URL, advertisedAs branch: ShareFileBranch) {
        Task { [weak self] in
            guard let self else { return }
            guard let payload = await Self.readSharedFile(from: url) else {
                self.finish(.complete)
                return
            }

            switch ShareInputResolver.classify(fileName: payload.name, advertisedAs: branch) {
            case .nzb:
                self.presentNZBFile(payload)
            case .torrent:
                self.presentTorrentFile(payload)
            case .unusable:
                self.finish(.complete)
            }
        }
    }

    private func presentShareUI() {
        let schema = TrawlModelSchema.full
        let config = ModelConfiguration(
            schema: schema,
            groupContainer: .identifier(AppGroup.identifier)
        )

        guard let container = try? ModelContainer(
            for: schema,
            configurations: [config]
        ) else {
            finish(.complete)
            return
        }

        let shareView = ShareAddTorrentView(
            magnetURL: magnetURL,
            torrentFileData: torrentFileData,
            torrentFileName: torrentFileName,
            nzbURL: nzbURL,
            nzbFileData: nzbFileData,
            nzbFileName: nzbFileName,
            onComplete: { [weak self] in self?.finish(.complete) },
            onCancel: { [weak self] in self?.finish(.complete) }
        )
        .modelContainer(container)

        let hostingController = UIHostingController(rootView: shareView)
        hostingController.modalPresentationStyle = UIModalPresentationStyle.formSheet

        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        hostingController.didMove(toParent: self)
    }

    /// The one and only way this extension ends. The gate decides whether this
    /// call is the one that counts; if it is, the temporary state is dropped and
    /// the `NSExtensionContext` half is performed here, on the main actor.
    private func finish(_ termination: ShareTermination) {
        guard let termination = terminationGate.claim(termination) else { return }

        magnetURL = nil
        torrentFileData = nil
        torrentFileName = nil
        nzbURL = nil
        nzbFileData = nil
        nzbFileName = nil

        switch termination {
        case .complete:
            extensionContext?.completeRequest(returningItems: nil)
        case .cancel(let message):
            extensionContext?.cancelRequest(withError: ShareInputError(message: message))
        }
    }

    private func presentTorrentFile(_ payload: SharedTorrentFile) {
        torrentFileData = payload.data
        torrentFileName = payload.name
        presentShareUI()
    }

    private func presentNZBFile(_ payload: SharedTorrentFile) {
        nzbFileData = payload.data
        nzbFileName = payload.name
        presentShareUI()
    }

    nonisolated private static func readSharedFile(from url: URL) async -> SharedTorrentFile? {
        await Task.detached(priority: .userInitiated) {
            guard url.startAccessingSecurityScopedResource() else {
                return nil
            }
            defer { url.stopAccessingSecurityScopedResource() }

            guard let data = try? Data(contentsOf: url) else {
                return nil
            }

            return SharedTorrentFile(data: data, name: url.lastPathComponent)
        }.value
    }
}

private struct SharedTorrentFile: Sendable {
    let data: Data
    let name: String
}

/// Carries a `ShareTermination`'s message into `cancelRequest(withError:)`.
/// Mirrors the `ShareNZBError` idiom next door: the message is the whole payload.
private nonisolated struct ShareInputError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}
