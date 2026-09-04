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
        .toolbarBackground(.hidden, for: .navigationBar)
        // Light contents only when this fills the screen. As a *pane* the bar is the
        // whole column's, and the list on the other half of it is on a pale
        // background - so forcing the bar's text white there makes the screen's own
        // toolbar buttons vanish into it.
        .toolbarColorScheme(isDetailPane ? nil : .dark, for: .navigationBar)
        #endif
    }
}
