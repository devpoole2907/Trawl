import SwiftUI

struct ArrLibraryListView<Item: Identifiable, Row: View>: View where Item.ID == Int {
    let items: [Item]
    let isLoading: Bool
    let error: String?
    let nounSingular: String
    let nounPlural: String
    let emptyIcon: String
    let titleKeyPath: KeyPath<Item, String>
    var sectionTitle: ((Item) -> String)?
    var usesTitleSections = true
    let selectedIDs: Set<Int>
    let row: (Item, Bool) -> Row
    let retry: (() async -> Void)?

    var body: some View {
        if isLoading && items.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error, items.isEmpty {
            ContentUnavailableView {
                Label("Failed to Load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                if let retry {
                    Button("Retry") { Task { await retry() } }
                }
            }
        } else {
            // Keep the List mounted even when filtering yields zero results so the
            // segment-bar search field doesn't lose keyboard focus the moment the
            // results drop to empty. Swapping the List out for a ContentUnavailableView
            // tears down the scroll container and resigns first responder.
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
            List {
                ForEach(sections) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            row(item, selectedIDs.contains(item.id))
                                .listRowBackground(Color.clear)
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
        List {
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        row(item, selectedIDs.contains(item.id))
                            .listRowBackground(Color.clear)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var flatList: some View {
        List {
            ForEach(items) { item in
                row(item, selectedIDs.contains(item.id))
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}
