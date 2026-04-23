import UIKit
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
    private var magnetURL: String?
    private var torrentFileData: Data?
    private var torrentFileName: String?

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
                // Check for URLs (magnet links)
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] item, _ in
                        guard let url = item as? URL else { return }
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            self.magnetURL = url.absoluteString
                            self.presentShareUI()
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
                            guard let payload = await Self.readTorrentFile(from: url) else {
                                await self.clearSharedFileAndClose()
                                return
                            }
                            await self.presentTorrentFile(payload)
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
        let schema = Schema([
            ServerProfile.self,
            CachedTorrentState.self,
            RecentSavePath.self,
            ArrServiceProfile.self,
            SSHProfile.self
        ])
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

    private func clearSharedFileAndClose() {
        torrentFileData = nil
        torrentFileName = nil
        close()
    }

    nonisolated private static func readTorrentFile(from url: URL) async -> SharedTorrentFile? {
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
