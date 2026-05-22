import SwiftUI

struct TrawlSegmentBar<Selection: Hashable>: View {
    let title: String
    @Binding var selection: Selection
    let items: [TrawlSegmentBarItem<Selection>]
    var horizontalPadding: CGFloat = 15
    var alignment: TrawlSegmentBarAlignment = .leading
    var searchHint: String?
    var searchText: Binding<String>?
    var externalSearchExpanded: Binding<Bool>?
    var searchPlacement: TrawlSegmentBarSearchPlacement = .trailing
    var onSearchActivated: (Bool) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme
    @State private var viewSize: CGSize = .zero
    @State private var internalSearchExpanded = false
    @State private var allowsSearchRefocus = true
    @FocusState private var isKeyboardActive: Bool

    init(
        _ title: String,
        selection: Binding<Selection>,
        items: [TrawlSegmentBarItem<Selection>],
        horizontalPadding: CGFloat = 15,
        alignment: TrawlSegmentBarAlignment = .leading
    ) {
        self.title = title
        _selection = selection
        self.items = items
        self.horizontalPadding = horizontalPadding
        self.alignment = alignment
    }

    init(
        _ title: String,
        selection: Binding<Selection>,
        items: [TrawlSegmentBarItem<Selection>],
        searchText: Binding<String>,
        searchHint: String,
        isSearchExpanded: Binding<Bool>? = nil,
        searchPlacement: TrawlSegmentBarSearchPlacement = .trailing,
        horizontalPadding: CGFloat = 15,
        alignment: TrawlSegmentBarAlignment = .leading,
        onSearchActivated: @escaping (Bool) -> Void = { _ in }
    ) {
        self.title = title
        _selection = selection
        self.items = items
        self.horizontalPadding = horizontalPadding
        self.alignment = alignment
        self.searchText = searchText
        self.searchHint = searchHint
        self.externalSearchExpanded = isSearchExpanded
        self.searchPlacement = searchPlacement
        self.onSearchActivated = onSearchActivated
    }

    private let animation: Animation = .interpolatingSpring(duration: 0.3, bounce: 0, initialVelocity: 0)

    var body: some View {
        let offsetsExpandedSearch = searchPlacement == .trailing

        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                if searchPlacement == .leading, searchText != nil {
                    expandableSearchBar
                }

                ForEach(items) { item in
                    itemView(item)
                }

                if searchPlacement == .trailing, searchText != nil {
                    expandableSearchBar
                }
            }
            .padding(.horizontal, horizontalPadding)
            .frame(minWidth: viewSize.width, alignment: frameAlignment)
            .visualEffect { [isSearchExpanded, viewSize, offsetsExpandedSearch] content, proxy in
                let rect = proxy.frame(in: .scrollView)
                let maxX = rect.maxX - viewSize.width
                let offset = offsetsExpandedSearch ? -maxX : 0

                return content
                    .offset(x: isSearchExpanded ? offset : 0)
            }
        }
        .frame(height: 50)
        .scrollDisabled(isSearchExpanded)
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .animation(animation, value: selection)
        .animation(animation, value: isKeyboardActive)
        .accessibilityLabel(title)
        .onChange(of: isKeyboardActive) { _, newValue in
            onSearchActivated(newValue)
            guard !newValue, isSearchExpanded, allowsSearchRefocus else { return }
            Task { @MainActor in
                isKeyboardActive = true
            }
        }
        .onGeometryChange(for: CGSize.self) {
            $0.size
        } action: { newValue in
            viewSize = newValue
        }
    }

    private var frameAlignment: Alignment {
        alignment == .center && searchText == nil ? .center : .leading
    }

    @ViewBuilder
    private func itemView(_ item: TrawlSegmentBarItem<Selection>) -> some View {
        let isLast = items.last?.id == item.id && searchPlacement == .trailing && isSearchExpanded
        let isFirst = items.first?.id == item.id && searchPlacement == .leading && isSearchExpanded

        ZStack {
            if isLast || isFirst {
                Button {
                    allowsSearchRefocus = false
                    searchText?.wrappedValue = ""
                    isKeyboardActive = false
                    withAnimation(animation) {
                        isSearchExpanded = false
                    }
                } label: {
                    Image(systemName: "circle.grid.2x2.fill")
                        .frame(width: 60, height: 45)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .padding(isLast ? .leading : .trailing, 12)
            } else {
                TrawlSegmentBarButton(
                    item: item,
                    isSelected: selection == item.value,
                    foregroundTint: foregroundTint(for: item),
                    backgroundTint: backgroundTint(for: item),
                    isSearchExpanded: isSearchExpanded
                ) {
                    selection = item.value
                }
                .disabled(isSearchExpanded)
            }
        }
    }

    private func foregroundTint(for item: TrawlSegmentBarItem<Selection>) -> Color {
        selection == item.value ? (colorScheme != .dark ? .white : .black) : .primary
    }

    private func backgroundTint(for item: TrawlSegmentBarItem<Selection>) -> Color {
        selection == item.value ? (colorScheme == .dark ? .white : .black) : .clear
    }

    private var isSearchExpanded: Bool {
        get { externalSearchExpanded?.wrappedValue ?? internalSearchExpanded }
        nonmutating set {
            if externalSearchExpanded != nil {
                externalSearchExpanded?.wrappedValue = newValue
            } else {
                internalSearchExpanded = newValue
            }
        }
    }

    @ViewBuilder
    private var expandableSearchBar: some View {
        let fitSearchBarWidth: CGFloat = max(viewSize.width - 102, 60)

        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .frame(width: isSearchExpanded ? 40 : 60)

                if isSearchExpanded, let searchText {
                    TextField(searchHint ?? "", text: searchText)
                        .focused($isKeyboardActive)
                }
            }
            .padding(.leading, isSearchExpanded ? 5 : 0)
            .padding(.trailing, isSearchExpanded ? 15 : 0)
            .frame(height: 45)
            .clipShape(.capsule)
            .glassEffect(.regular.interactive(), in: .capsule)
            .contentShape(.capsule)
            .gesture(
                TapGesture(count: 1).onEnded { _ in
                    allowsSearchRefocus = true
                    withAnimation(animation) {
                        isSearchExpanded = true
                    }
                    Task { @MainActor in
                        isKeyboardActive = true
                    }
                },
                isEnabled: !isSearchExpanded
            )
            .zIndex(1)
            .padding(.trailing, isKeyboardActive ? 57 : 0)

            Button {
                allowsSearchRefocus = false
                searchText?.wrappedValue = ""
                isKeyboardActive = false
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 45, height: 45)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .opacity(isKeyboardActive ? 1 : 0)
            .zIndex(0)
        }
        .frame(width: isSearchExpanded ? fitSearchBarWidth : nil)
    }
}

private struct TrawlSegmentBarButton<Selection: Hashable>: View {
    let item: TrawlSegmentBarItem<Selection>
    let isSelected: Bool
    let foregroundTint: Color
    let backgroundTint: Color
    let isSearchExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(item.title)
                .padding(.horizontal, 15)
                .frame(height: 45)
                .foregroundStyle(foregroundTint)
                .background(backgroundTint, in: .capsule)
                .glassEffect(.regular.interactive(!isSearchExpanded), in: .capsule)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .id(item.value)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

#Preview {
    @Previewable @State var selection = "Explore"

    TrawlSegmentBar(
        "Sections",
        selection: $selection,
        items: [
            TrawlSegmentBarItem("For You", value: "For You"),
            TrawlSegmentBarItem("Explore", value: "Explore"),
            TrawlSegmentBarItem("Plans", value: "Plans"),
            TrawlSegmentBarItem("Library", value: "Library")
        ]
    )
    .padding(.vertical)
}
