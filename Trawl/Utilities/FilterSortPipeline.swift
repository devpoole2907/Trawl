import Foundation

enum FilterSortPipeline {
    nonisolated static func apply<Item, Filter, Sort>(
        items: [Item],
        filter: Filter,
        searchText: String,
        sort: Sort,
        matchesSearch: (Item, String) -> Bool,
        matchesFilter: (Item, Filter) -> Bool,
        areInIncreasingOrder: (Item, Item, Sort) -> Bool
    ) -> [Item] {
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        let filteredItems = items.filter { item in
            matchesFilter(item, filter) &&
            (trimmedSearchText.isEmpty || matchesSearch(item, trimmedSearchText))
        }

        return filteredItems.sorted { lhs, rhs in
            areInIncreasingOrder(lhs, rhs, sort)
        }
    }
}
