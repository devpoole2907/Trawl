import SwiftUI
#if os(iOS)
import UIKit
private typealias PlatformImage = UIImage
#elseif os(macOS)
import AppKit
private typealias PlatformImage = NSImage
#endif

struct ArrArtworkView<Placeholder: View>: View {
    let url: URL?
    let contentMode: ContentMode
    let placeholder: Placeholder

    @State private var image: Image?

    init(
        url: URL?,
        contentMode: ContentMode = .fill,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.url = url
        self.contentMode = contentMode
        self.placeholder = placeholder()
    }

    var body: some View {
        ZStack {
            if let image {
                image
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                placeholder
            }
        }
        .task(id: url) {
            await loadImage()
        }
    }

    @MainActor
    private func loadImage() async {
        guard let url else {
            image = nil
            return
        }

        do {
            let data = try await ArtworkCache.shared.imageData(for: url)
            // Decode image on a background thread to avoid blocking the main thread
            let platformImage = await Task.detached(priority: .userInitiated) {
                PlatformImage(data: data)
            }.value
            guard let platformImage else {
                image = nil
                return
            }
            image = Image(platformImage: platformImage)
        } catch {
            image = nil
        }
    }
}

private extension Image {
    init(platformImage: PlatformImage) {
        #if os(iOS)
        self.init(uiImage: platformImage)
        #elseif os(macOS)
        self.init(nsImage: platformImage)
        #endif
    }
}
