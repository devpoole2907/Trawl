import SwiftUI
import TipKit

/// What the iPhone Library tab is showing: everything, or one kind of title.
///
/// iPhone only. The sidebar has room for Series and Movies as rows of their own, and
/// keeps them; the tab bar does not, and gave the slot to Calendar instead. Stored by
/// raw value, so the tab reopens on whatever the user last picked.
enum LibraryScope: String, CaseIterable, Identifiable, Hashable {
    case all
    case series
    case movies

    var id: Self { self }

    /// "Library" for everything - the tab's own name, rather than "All", which says
    /// nothing on its own in a navigation bar.
    var title: String {
        switch self {
        case .all: "Library"
        case .series: "Series"
        case .movies: "Movies"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "rectangle.stack"
        case .series: ServiceIdentity.sonarr.tabSystemImage
        case .movies: ServiceIdentity.radarr.tabSystemImage
        }
    }

    static let storageKey = "libraryScope"

    /// The count line under the title: "37 movies, 3 series".
    ///
    /// Movies first, as the user described it, and a kind with nothing in it is
    /// left out rather than spelled "0 series".
    static func countSummary(series: Int, movies: Int) -> String {
        var parts: [String] = []
        if movies > 0 { parts.append(movies == 1 ? "1 movie" : "\(movies) movies") }
        if series > 0 { parts.append("\(series) series") }
        return parts.isEmpty ? "No titles" : parts.joined(separator: ", ")
    }
}

/// The Library tab's scope picker, as menu content.
///
/// Its own view so every screen the Library tab can show - the combined list and
/// both single-kind lists - offers the same three choices in the same order, and
/// choosing one dismisses the tip the same way.
struct LibraryScopePicker: View {
    @Binding var scope: LibraryScope

    var body: some View {
        Picker("Library", selection: Binding(
            get: { scope },
            set: { newValue in
                LibraryScopeTip().invalidate(reason: .actionPerformed)
                withAnimation(.snappy) { scope = newValue }
            }
        )) {
            ForEach(LibraryScope.allCases) { option in
                Label(option.title, systemImage: option.systemImage)
                    .tag(option)
            }
        }
        .pickerStyle(.inline)
    }
}

extension View {
    /// Anchors `LibraryScopeTip` to a Library title menu, arrow pointing up at it.
    ///
    /// `.top` is the edge the arrow comes out of, which puts the bubble under the
    /// navigation bar with its point on the title.
    @ViewBuilder
    func libraryScopeTip(isShown: Bool) -> some View {
        if isShown {
            popoverTip(LibraryScopeTip(), arrowEdge: .top)
        } else {
            self
        }
    }
}

/// The Library tab's title when it is only the scope switch: the combined list, and
/// a Series or Movies screen whose service is not set up or not reachable.
///
/// The second case is why this exists. Without it, choosing Series on a phone with no
/// Sonarr left a "Sonarr Not Set Up" screen titled "Series" and no way back to Movies.
private struct LibraryScopeTitleMenu: ViewModifier {
    @Binding var scope: LibraryScope
    var subtitle: String?
    @State private var isCompact = false

    func body(content: Content) -> some View {
        content
            .navigationTitle("")
            #if os(iOS)
            .toolbarTitleDisplayMode(.inline)
            #endif
            .trawlTitleMenuShrinksOnScroll($isCompact)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    TrawlTitleMenu(
                        options: LibraryScope.allCases.map {
                            TrawlTitleMenuOption(value: $0, title: $0.title, systemImage: $0.systemImage)
                        },
                        selection: Binding(
                            get: { scope },
                            set: { newValue in
                                LibraryScopeTip().invalidate(reason: .actionPerformed)
                                scope = newValue
                            }
                        ),
                        isCompact: isCompact,
                        subtitle: subtitle
                    )
                    .libraryScopeTip(isShown: true)
                }
            }
    }
}

extension View {
    /// Replaces the navigation title with the Library scope menu when `scope` is set.
    @ViewBuilder
    func libraryScopeTitleMenu(_ scope: Binding<LibraryScope>?, subtitle: String? = nil) -> some View {
        if let scope {
            modifier(LibraryScopeTitleMenu(scope: scope, subtitle: subtitle))
        } else {
            self
        }
    }
}
