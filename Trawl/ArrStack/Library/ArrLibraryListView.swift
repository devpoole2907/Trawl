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
        ArrLoadingErrorEmptyView(
            isLoading: isLoading,
            error: error,
            isEmpty: items.isEmpty,
            emptyTitle: "No \(nounPlural)",
            emptyIcon: emptyIcon,
            emptyDescription: "No \(nounPlural.lowercased()) match the current filter.",
            onRetry: retry
        ) {
            if usesTitleSections {
                sectionedList
            } else {
                flatList
            }
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
                        }
                    }
                    .sectionIndexLabel(Text(section.indexLabel))
                }
            }
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
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var flatList: some View {
        List {
            ForEach(items) { item in
                row(item, selectedIDs.contains(item.id))
            }
        }
        .scrollContentBackground(.hidden)
    }
}
