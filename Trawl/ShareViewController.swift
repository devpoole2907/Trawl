import UIKit
import SwiftUI
import SwiftData
import UniformTypeIdentifiers

class ShareViewController: UIViewController {
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
                        if let url = item as? URL {
                            if url.scheme == "magnet" {
                                self?.magnetURL = url.absoluteString
                            } else {
                                // Could be a .torrent URL — try to download
                                self?.magnetURL = url.absoluteString
                            }
                            DispatchQueue.main.async { self?.presentShareUI() }
                        }
                    }
                    return
                }

                // Check for .torrent files
                let torrentType = UTType(filenameExtension: "torrent") ?? .data
                if provider.hasItemConformingToTypeIdentifier(torrentType.identifier) {
                    provider.loadItem(forTypeIdentifier: torrentType.identifier) { [weak self] item, _ in
                        if let url = item as? URL {
                            _ = url.startAccessingSecurityScopedResource()
                            defer { url.stopAccessingSecurityScopedResource() }
                            self?.torrentFileData = try? Data(contentsOf: url)
                            self?.torrentFileName = url.lastPathComponent
                            DispatchQueue.main.async { self?.presentShareUI() }
                        }
                    }
                    return
                }

                // Check for plain text (magnet links pasted as text)
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { [weak self] item, _ in
                        if let text = item as? String, text.lowercased().hasPrefix("magnet:") {
                            self?.magnetURL = text
                            DispatchQueue.main.async { self?.presentShareUI() }
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
            RecentSavePath.self
        ])
        let config = ModelConfiguration(
            groupContainer: .identifier(AppGroup.identifier)
        )

        guard let container = try? ModelContainer(for: schema, configurations: [config]) else {
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
        hostingController.modalPresentationStyle = .formSheet

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
}
