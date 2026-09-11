import SwiftUI

/// Renders one column of the root NavigationSplitView. Outside that split view,
/// the list is a normal navigation destination and its rows push their details.
/// Columns are never simulated with an HStack or a second inset title.
struct TrawlListDetailPanes<ListContent: View, DetailContent: View>: View {
    @Environment(\.sidebarNavigationColumn) private var column

    var title: String
    var subtitle: String?
    @ViewBuilder var list: ListContent
    @ViewBuilder var detail: DetailContent

    var body: some View {
        Group {
            if column == .detail {
                detail
                    .environment(\.isDetailPane, true)
            } else {
                list
                    .navigationTitle(title)
                    .navigationSubtitle(subtitle ?? "")
                    .environment(\.isDetailPane, false)
            }
        }
        // Only these roots participate in the sidebar's selection. Screens pushed
        // from either column own their navigation normally.
        .environment(\.sidebarNavigationColumn, nil)
        .environment(\.hasDetailPane, column == .content)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

extension EnvironmentValues {
    @Entry var sidebarNavigationColumn: NavigationSplitViewColumn? = nil
}

/// What a screen's detail column should say when nothing is selected.
///
/// A three-column destination is built once per column, so a screen whose service is
/// unavailable used to draw its "Not Set Up" card in the content column *and* again in
/// the detail column - the same message twice, side by side, and two Open Settings
/// buttons with it. The detail column should keep saying what it always says when
/// nothing is selected, exactly as it does once the service is configured.
///
/// Requests already behaved this way, through a one-off `title == "Requests"` test in
/// `MoreView.seerrAdminDestination`. These cases are that special case generalised, and
/// each one repeats the string its own screen already uses so the column does not
/// change its wording depending on whether the server is reachable.
struct DetailPanePlaceholder {
    let title: String
    let systemImage: String

    static let library = Self(title: "Select a Library", systemImage: "folder")
    static let session = Self(title: "Select a Session", systemImage: "play.rectangle.on.rectangle")
    static let plugin = Self(title: "Select a Plugin", systemImage: "puzzlepiece.extension")
    static let user = Self(title: "Select a User", systemImage: "person.2")
    static let issue = Self(title: "Select an Issue", systemImage: "exclamationmark.bubble")
    static let request = Self(title: "Select a Request", systemImage: "square.and.arrow.down.on.square")
    static let newsServer = Self(title: "Select a News Server", systemImage: "server.rack")
}

extension View {
    /// The right-hand pane's placeholder, in the one shape every screen uses.
    func listDetailPlaceholder(_ title: String, systemImage: String) -> some View {
        ContentUnavailableView(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #if os(macOS)
            // The window's toolbar only splits into per-column regions for columns
            // that contribute items. With an empty detail the list column's
            // .primaryAction items resolve against the window's trailing edge and
            // float out over this placeholder, then jump back over the list as soon
            // as a selection brings its own toolbar. A zero-sized item claims the
            // detail's region from the start so they never move. EmptyView is
            // dropped outright, so it has to be a real view.
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Color.clear.frame(width: 0, height: 0)
                }
            }
            #endif
    }
}

private struct IsDetailPaneKey: EnvironmentKey {
    static let defaultValue = false
}

private struct HasDetailPaneKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether this view is the root of a native detail column. Screens can use
    /// this to name the selected scope rather than repeat the list's title.
    var isDetailPane: Bool {
        get { self[IsDetailPaneKey.self] }
        set { self[IsDetailPaneKey.self] = newValue }
    }

    /// Whether this list has a detail pane beside it, so a row should *select*
    /// rather than push.
    ///
    /// Read by the list rather than re-derived from the size class, because the size
    /// class does not answer this question reliably: a `NavigationSplitView`'s
    /// content column reports itself compact on iPad. The view that decided to show
    /// two panes says so directly instead.
    var hasDetailPane: Bool {
        get { self[HasDetailPaneKey.self] }
        set { self[HasDetailPaneKey.self] = newValue }
    }
}

extension View {
    /// Uses a scope-specific title when the screen occupies a native detail column.
    /// Both the list and detail retain independent navigation bars.
    func paneAwareNavigationTitle(
        _ title: String,
        subtitle: String? = nil,
        whenPane paneTitle: String? = nil
    ) -> some View {
        modifier(PaneAwareNavigationTitle(title: title, subtitle: subtitle, paneTitle: paneTitle))
    }
}

private struct PaneAwareNavigationTitle: ViewModifier {
    @Environment(\.isDetailPane) private var isDetailPane

    let title: String
    let subtitle: String?
    let paneTitle: String?

    func body(content: Content) -> some View {
        if isDetailPane, let paneTitle {
            content
                .navigationTitle(paneTitle)
                .navigationSubtitle("")
        } else {
            content
                .navigationTitle(title)
                .navigationSubtitle(subtitle ?? "")
        }
    }
}
