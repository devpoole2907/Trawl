import SwiftUI

/// Selection opens a sidebar detail; a compact row confirms an automatic search.
struct WantedItemActionRow<Label: View>: View {
    let title: String
    var isSelected = false
    var onSelect: (() -> Void)?
    let onSearch: @MainActor () async -> Void
    @ViewBuilder var label: Label
    @State private var confirmsSearch = false
    @State private var isSearching = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                if let onSelect { onSelect() } else { confirmsSearch = true }
            } label: {
                label.frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isSearching {
                ProgressView().controlSize(.small)
            } else if onSelect != nil {
                Button("Search", systemImage: "magnifyingglass") { confirmsSearch = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.18) : nil)
        .disabled(isSearching)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Search", systemImage: "magnifyingglass") { confirmsSearch = true }
                .tint(.purple)
        }
        .confirmationDialog("Search for \(title)?", isPresented: $confirmsSearch, titleVisibility: .visible) {
            Button("Search") {
                Task {
                    isSearching = true
                    await onSearch()
                    isSearching = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Start an automatic search for this missing item?")
        }
    }
}
