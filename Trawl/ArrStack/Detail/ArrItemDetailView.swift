import SwiftUI

struct ArrDetailAction: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let action: () -> Void
}

struct ArrItemDetailView<Item, BodyContent: View>: View {
    @Environment(\.isDetailPane) private var isDetailPane

    let item: Item?
    let title: String
    let backgroundURL: URL?
    @ViewBuilder let bodyContent: (Item) -> BodyContent

    var body: some View {
        Group {
            if let item {
                bodyContent(item)
                    .environment(\.colorScheme, .dark)
                    .background {
                        ArrArtworkView(url: backgroundURL, contentMode: .fill) {
                            Rectangle().fill(Color.purple.opacity(0.5))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .scaleEffect(1.4)
                        .blur(radius: 60)
                        .saturation(1.6)
                        .overlay(Color.black.opacity(0.55))
                        .ignoresSafeArea()
                    }
            } else {
                ContentUnavailableView("\(title) Not Found", systemImage: "questionmark.circle")
            }
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // Only as a screen of its own. A hidden bar background lets the artwork run
        // up behind the title, which is the point - but as a *pane* the bar is the
        // whole column's, and hiding it there leaves a white strip over the detail
        // (the artwork is clipped to the pane) with white-on-white text in it.
        .toolbarBackground(isDetailPane ? .visible : .hidden, for: .navigationBar)
        .toolbarColorScheme(isDetailPane ? nil : .dark, for: .navigationBar)
        #endif
    }
}
