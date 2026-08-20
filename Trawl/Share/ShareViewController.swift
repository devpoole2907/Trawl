import UIKit
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
    private var magnetURL: String?
    private var torrentFileData: Data?
    private var torrentFileName: String?
    private var nzbURL: String?
    private var nzbFileData: Data?
    private var nzbFileName: String?

    /// There is no system UTType for NZB, so the app declares `org.newzbin.nzb`
    /// in both Info.plists. Hosts that never saw the declaration hand the file
    /// over as plain XML instead, hence the fallback — the filename is what
    /// actually decides, matching `AddTorrentSheet`.
    nonisolated private static var nzbType: UTType { UTType("org.newzbin.nzb") ?? UTType(filenameExtension: "nzb") ?? .xml }

    override func viewDidLoad() {
        super.viewDidLoad()
        extractSharedContent()
    }

    private func extractSharedContent() {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            close()
            return
        }

        for item in extensionItems {
            guard let attachments = item.attachments else { continue }

            for provider in attachments {
                // Check for URLs (magnet links only — a magnet's scheme is "magnet").
                // Don't treat arbitrary shared web URLs as torrents.
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] item, _ in
                        guard let url = item as? URL else {
                            Task { @MainActor [weak self] in self?.close() }
                            return
                        }

                        // A shared http(s) link ending in .nzb is the realistic way an
                        // NZB URL reaches an app — indexers publish those, and no iOS
                        // app emits an `nzb:` scheme, so none is registered.
                        if Self.isNZBFileName(url.lastPathComponent),
                           let scheme = url.scheme?.lowercased(),
                           scheme == "http" || scheme == "https" {
                            let link = url.absoluteString
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                self.nzbURL = link
                                self.presentShareUI()
                            }
                            return
                        }

                        guard url.scheme?.lowercased() == "magnet" else {
                            Task { @MainActor [weak self] in self?.close() }
                            return
                        }
                        let magnet = url.absoluteString
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.magnetURL = magnet
                            self.presentShareUI()
                        }
                    }
                    return
                }

                // Check for .nzb files. Tested before .torrent because that branch
                // falls back to `.data`, which would otherwise swallow an NZB.
                if provider.hasItemConformingToTypeIdentifier(Self.nzbType.identifier) {
                    provider.loadItem(forTypeIdentifier: Self.nzbType.identifier) { [weak self] item, _ in
                        guard let url = item as? URL else { return }
                        Task { [weak self] in
                            guard let self else { return }
                            guard let payload = await Self.readSharedFile(from: url),
                                  Self.isNZBFileName(payload.name) else {
                                await self.clearSharedFileAndClose()
                                return
                            }
                            await self.presentNZBFile(payload)
                        }
                    }
                    return
                }

                // Check for .torrent files
                let torrentType = UTType(filenameExtension: "torrent") ?? .data
                if provider.hasItemConformingToTypeIdentifier(torrentType.identifier) {
                    provider.loadItem(forTypeIdentifier: torrentType.identifier) { [weak self] item, _ in
                        guard let url = item as? URL else { return }
                        Task { [weak self] in
                            guard let self else { return }
                            guard let payload = await Self.readSharedFile(from: url) else {
                                await self.clearSharedFileAndClose()
                                return
                            }
                            // Some hosts describe an NZB only as generic data, which the
                            // `?? .data` fallback above matches. The name settles it.
                            if Self.isNZBFileName(payload.name) {
                                await self.presentNZBFile(payload)
                            } else {
                                await self.presentTorrentFile(payload)
                            }
                        }
                    }
                    return
                }

                // Check for plain text (magnet links pasted as text)
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { [weak self] item, _ in
                        if let text = item as? String, text.lowercased().hasPrefix("magnet:") {
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                self.magnetURL = text
                                self.presentShareUI()
                            }
                        }
                    }
                    return
                }
            }
        }

        // Nothing usable found
        close()
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
            close()
            return
        }

        let shareView = ShareAddTorrentView(
            magnetURL: magnetURL,
            torrentFileData: torrentFileData,
            torrentFileName: torrentFileName,
            nzbURL: nzbURL,
            nzbFileData: nzbFileData,
            nzbFileName: nzbFileName,
            onComplete: { [weak self] in self?.close() },
            onCancel: { [weak self] in self?.close() }
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

    private func close() {
        extensionContext?.completeRequest(returningItems: nil)
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

    private func clearSharedFileAndClose() {
        torrentFileData = nil
        torrentFileName = nil
        nzbFileData = nil
        nzbFileName = nil
        close()
    }

    /// Mirrors `AddTorrentSheet.isNZBFileName` — SABnzbd also serves gzipped NZBs.
    nonisolated private static func isNZBFileName(_ fileName: String) -> Bool {
        let lowercased = fileName.lowercased()
        return lowercased.hasSuffix(".nzb") || lowercased.hasSuffix(".nzb.gz")
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
