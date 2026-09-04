import SwiftUI

struct ArrLibraryListView<Item: Identifiable, Row: View>: View {
    let items: [Item]
    let isLoading: Bool
    let error: String?
    let nounSingular: String
    let nounPlural: String
    let emptyIcon: String
    let titleKeyPath: KeyPath<Item, String>
    var sectionTitle: ((Item) -> String)?
    var usesTitleSections = true
    /// Bound rather than passed by value: the List owns selection now, so it
    /// needs to write back. The `Bool` handed to `row` stays, since a row may want
    /// to present itself differently while selected.
    @Binding var selection: Set<Item.ID>
    /// Single selection, for when this list is the content column of a split view.
    ///
    /// `nil` everywhere else, which is what keeps iPhone on the old behaviour: rows
    /// stay `NavigationLink`s and a tap pushes. When it is present the List owns the
    /// tap instead and the selection drives the detail column beside it - which is
    /// also the only way a selection can be made *programmatically*, and so the only
    /// way to open a library on its first item rather than on an empty pane.
    var navigationSelection: Binding<Item.ID?>?
    let row: (Item, Bool) -> Row
    let retry: (() async -> Void)?

    // `EditMode` is an iOS concept and the environment key does not exist on macOS,
    // which is what stopped TrawlMac building at all. The parent (`ArrMediaListView`)
    // already publishes it only under `#if os(iOS)`, so on macOS there is nothing to
    // read and nothing to read it from - `false` is the honest answer rather than a
    // stub, because a platform with no edit mode is never in one. Bulk selection on
    // the Mac would be a menu command and a different mechanism, not this one.
    #if os(iOS)
    @Environment(\.editMode) private var editMode

    private var isEditing: Bool { editMode?.wrappedValue.isEditing ?? false }
    #else
    private var isEditing: Bool { false }
    #endif

    /// Present only while editing, and that is load-bearing.
    ///
    /// The rows are `NavigationLink(value:)`s carrying the item's own id, and the
    /// selection set holds that same id type. Handing `List` a selection binding of
    /// the matching type makes it treat each row as selection-driven navigation and
    /// claim the tap, so tapping a title stopped pushing its detail screen. Outside
    /// edit mode there is nothing to select, so the binding is absent and the links
    /// behave as links again.
    private var listSelection: Binding<Set<Item.ID>>? { isEditing ? $selection : nil }

    /// Wraps the rows in the right kind of `List`.
    ///
    /// The two selection modes are different *types* - a `Set` for edit mode's
    /// multi-select, an optional single value for split-view navigation - so they
    /// cannot share one `List`. Editing wins when both are available: a split view
    /// still needs multi-select while the user is picking rows to delete.
    /// Rows are otherwise transparent so the screen's gradient shows through, and
    /// that transparency also swallowed the system's selection tint - the row driving
    /// the detail column looked exactly like every other row. Only the navigation
    /// selection is tinted here; edit mode draws its own checkmarks.
    @ViewBuilder
    private func rowBackground(for item: Item) -> some View {
        if !isEditing, let navigationSelection, navigationSelection.wrappedValue == item.id {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.16))
                .padding(.vertical, 2)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func selectableList<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if let navigationSelection, !isEditing {
            List(selection: navigationSelection) { content() }
        } else {
            List(selection: listSelection) { content() }
        }
    }

    var body: some View {
        if isLoading && items.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error, items.isEmpty {
            ServiceErrorView(title: "Failed to Load", message: error, systemImage: emptyIcon, onRetry: retry)
        } else {
            // Keep the List mounted even when filtering yields zero results so the
            // segment-bar search field doesn't lose keyboard focus the moment the
            // results drop to empty. Swapping the List out for a ContentUnavailableView
            // tears down the scroll container and resigns first responder.
            VStack(spacing: 0) {
                if let error {
                    ServiceErrorView(
                        title: "Failed to Refresh",
                        message: error,
                        hasContent: true,
                        systemImage: emptyIcon,
                        onRetry: retry
                    )
                }
                ZStack {
                    listContent
                        .opacity(items.isEmpty ? 0 : 1)
                        .allowsHitTesting(!items.isEmpty)

                    if items.isEmpty {
                        ContentUnavailableView {
                            Label("No \(nounPlural)", systemImage: emptyIcon)
                        } description: {
                            Text("No \(nounPlural.lowercased()) match the current filter.")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var listContent: some View {
        if usesTitleSections {
            sectionedList
        } else {
            flatList
        }
    }

    private var sections: [ArrTitleSection<Item>] {
        if let sectionTitle {
            groupByTitleSection(items, title: sectionTitle)
        } else {
            groupByTitleSection(items, keyPath: titleKeyPath)
        }
    }

    @ViewBuilder
    private var sectionedList: some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            selectableList {
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            row(item, selection.contains(item.id))
                                .listRowBackground(rowBackground(for: item))
                        }
                    }
                    .sectionIndexLabel(Text(section.indexLabel))
                }
            }
            .listStyle(.plain)
            .listSectionIndexVisibility(.visible)
            .scrollContentBackground(.hidden)
        } else {
            sectionedListWithoutIndex
        }
        #else
        sectionedListWithoutIndex
        #endif
    }

    private var sectionedListWithoutIndex: some View {
        selectableList {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        row(item, selection.contains(item.id))
                            .listRowBackground(rowBackground(for: item))
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var flatList: some View {
        selectableList {
            ForEach(items) { item in
                row(item, selection.contains(item.id))
                    .listRowBackground(rowBackground(for: item))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}
