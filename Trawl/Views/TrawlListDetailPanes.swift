//
//  TrawlListDetailPanes.swift
//  Trawl
//
//  A list beside its detail, for a screen that is already inside a navigation column.
//

import SwiftUI

/// Two panes side by side at regular width, and just the list at compact width.
///
/// Deliberately a *layout* rather than a navigation container. These screens are
/// already inside the iPad chrome's split view, and the column they land in has
/// exactly one navigation bar. Nothing put inside these panes changes that:
///
/// - A `NavigationSplitView` here nests one split view in another, and the inner
///   one's columns arrive under the outer column's bar - a band of empty chrome
///   across the top of the screen.
/// - A `NavigationStack` around a pane looks like it should contain that pane's bar
///   and does not. The stack reserves bar height inside the pane, but the pane's
///   `navigationTitle` still surfaces in the *column's* bar, so the screen ends up
///   with an empty strip and a title in the wrong place.
/// - Hiding the column's bar to make room for per-pane bars hides the panes' bars
///   too: `toolbar(_:for:)` is inherited by every navigation container beneath it,
///   and re-asserting `.visible` inside a pane does not win it back. Neither does
///   applying the hide from a leaf that is not an ancestor of the panes.
///
/// So the column's one bar is what these screens have, and the job is to make it
/// read correctly rather than to conjure a second one. The bar's title slot is
/// centred on the column, which puts it over the detail - so that is what it is used
/// for: the detail pane keeps its own `navigationTitle`, and the screen's name is
/// pinned above the list instead. Each name ends up over the pane it belongs to, and
/// selecting a row no longer blanks the screen's name and replaces it with the
/// selection's.
///
/// Inline, always. A large title is drawn over the list pane and reserves its full
/// height across the *whole* column, which showed as a tall white band above the
/// detail with nothing in it.
///
/// Rows still push rather than select at compact width, where the list *is* the whole
/// window.
struct TrawlListDetailPanes<ListContent: View, DetailContent: View>: View {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #endif

    /// How wide the list pane is allowed to be. The default matches the chrome's own
    /// content column, so a screen with two panes reads as part of the same app
    /// rather than as its own arrangement.
    var listWidth: ClosedRange<CGFloat> = 320...420

    /// The screen's own name, shown in the column's bar whichever pane is active.
    var title: String
    /// The server or scope the screen is showing, where it has one.
    var subtitle: String?

    @ViewBuilder var list: ListContent
    @ViewBuilder var detail: DetailContent

    private var showsBothPanes: Bool {
        #if os(iOS)
        hSizeClass == .regular
        #else
        true
        #endif
    }

    var body: some View {
        if showsBothPanes {
            HStack(spacing: 0) {
                list
                    .environment(\.hasDetailPane, true)
                    .safeAreaInset(edge: .top, spacing: 0) { screenName }
                    .frame(minWidth: listWidth.lowerBound, idealWidth: listWidth.lowerBound, maxWidth: listWidth.upperBound)

                Divider()

                detail
                    .environment(\.isDetailPane, true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Clipped sideways only. Detail screens paint full-bleed artwork
                    // backgrounds - scaled up, blurred, and ignoring the safe area -
                    // and `ignoresSafeArea` resolves against the *column* rather than
                    // the pane, so that artwork spreads across the list beside it. It
                    // cannot be contained at the source, because everything inside
                    // the modifier is handed the column-sized proposal too.
                    //
                    // A plain `clipped` also cuts the strip beneath the shared
                    // navigation bar, and the pane's background with it: the detail
                    // then sat under a band of bare white while the list's background
                    // ran up behind the bar as it should. The mask keeps the pane's
                    // width and lets it grow past its own top and bottom, which is
                    // the only direction the overspill needs to be allowed in.
                    .mask {
                        Rectangle().padding(.vertical, -600)
                    }
                    // A clip stops the drawing, not the touches. Without this the
                    // list sat under an invisible sheet of artwork and its rows
                    // stopped responding the moment anything was selected.
                    .contentShape(Rectangle())
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            // One bar across two panes, so it is drawn as one. Left to itself each
            // pane's scroll view decides the background over its own half, and the
            // usual answer - list at rest, detail scrolled under - is a bar that is
            // clear over the list and opaque white over the detail, split down the
            // middle. Hidden rather than visible: these screens paint their own
            // background and it should run the full width behind the bar, which is
            // what the list half was already doing.
            .toolbarBackground(.hidden, for: .navigationBar)
            #endif
        } else {
            list
                .navigationTitle(title)
                .navigationSubtitle(subtitle ?? "")
        }
    }

    /// The screen's name, pinned above the list rather than written into the bar.
    ///
    /// The bar's title slot is centred on the *column*, which puts anything in it
    /// over the detail pane; and the bar's leading slot squeezes a label down to an
    /// ellipsis, because a toolbar item there is sized for a control rather than for
    /// text. Above the list is where this name belongs and where there is room for
    /// it, so it goes there and the bar's title is left to the detail.
    ///
    /// Applied here rather than by each caller, so it lands *above* any inset the
    /// list already has - a later inset is the outer one.
    private var screenName: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.title3.weight(.semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        // Named, so a test can ask whether the *screen* is still identified after a
        // row is picked without matching whatever the bar happens to say - which is
        // now the detail's name, and on some screens is the same words.
        .accessibilityIdentifier(Self.screenNameIdentifier)
    }

    /// The accessibility identifier on the screen's name.
    static var screenNameIdentifier: String { "list-detail-screen-name" }
}

extension View {
    /// The right-hand pane's placeholder, in the one shape every screen uses.
    func listDetailPlaceholder(_ title: String, systemImage: String) -> some View {
        ContentUnavailableView(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct IsDetailPaneKey: EnvironmentKey {
    static let defaultValue = false
}

private struct HasDetailPaneKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether the view is being shown as `TrawlListDetailPanes`' right-hand pane
    /// rather than as a screen of its own.
    ///
    /// A pane shares the column's navigation bar with the list beside it, so chrome
    /// that is right for a whole screen - hiding the bar's background to let artwork
    /// through, forcing its contents light - is wrong here, where it applies to both
    /// panes at once.
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
    /// Names a screen that is sometimes a destination of its own and sometimes
    /// somebody's detail pane - the Prowlarr indexer detail, the Arr download-client
    /// list, and the rest of the views `TrawlListDetailPanes` shows on the right.
    ///
    /// Both readings want the same thing now: the view names itself. As a destination
    /// that is the column's title; as a pane it is the column's title too, and the
    /// screen around it has moved its own name out to the bar's leading slot rather
    /// than competing for the centre. The suppression this used to do - a pane naming
    /// nothing, so the screen's title survived - is gone with it.
    /// - Parameter whenPane: what to call this view while it is somebody's detail
    ///   pane. Some of these views repeat the name of the screen that holds them -
    ///   the Sonarr download-client list is itself "Download Clients" - and the bar
    ///   saying what the header beside it already says is the duplication this whole
    ///   arrangement exists to remove. A pane name replaces the subtitle as well,
    ///   since the scope is usually what the shorter name *is*.
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
