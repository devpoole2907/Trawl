import Foundation

struct ArrTitleSection<Item: Identifiable>: Identifiable {
    let title: String
    let indexLabel: String
    let items: [Item]

    var id: String { indexLabel }
}

func sectionLabel(for title: String) -> String {
    guard let scalar = title.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.first else {
        return "#"
    }

    let label = String(scalar).uppercased()
    return label.range(of: "[A-Z]", options: .regularExpression) != nil ? label : "#"
}

func groupByTitleSection<Item: Identifiable>(
    _ items: [Item],
    keyPath: KeyPath<Item, String>
) -> [ArrTitleSection<Item>] {
    groupByTitleSection(items) { item in
        item[keyPath: keyPath]
    }
}

func groupByTitleSection<Item: Identifiable>(
    _ items: [Item],
    title: (Item) -> String
) -> [ArrTitleSection<Item>] {
    let grouped = Dictionary(grouping: items) { item in
        sectionLabel(for: title(item))
    }

    return grouped.keys.sorted().map { label in
        ArrTitleSection(
            title: label,
            indexLabel: label,
            items: grouped[label] ?? []
        )
    }
}
