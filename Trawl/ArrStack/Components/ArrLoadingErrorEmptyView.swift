import SwiftUI

struct ArrLoadingErrorEmptyView<Content: View>: View {
    let isLoading: Bool
    let error: String?
    let isEmpty: Bool
    let emptyTitle: LocalizedStringKey
    let emptyIcon: String
    let emptyDescription: LocalizedStringKey?
    let searchText: String?
    let onRetry: (() async -> Void)?
    let content: Content

    init(
        isLoading: Bool,
        error: String?,
        isEmpty: Bool,
        emptyTitle: LocalizedStringKey,
        emptyIcon: String,
        emptyDescription: LocalizedStringKey?,
        searchText: String? = nil,
        onRetry: (() async -> Void)?,
        @ViewBuilder content: () -> Content
    ) {
        self.isLoading = isLoading
        self.error = error
        self.isEmpty = isEmpty
        self.emptyTitle = emptyTitle
        self.emptyIcon = emptyIcon
        self.emptyDescription = emptyDescription
        self.searchText = searchText
        self.onRetry = onRetry
        self.content = content()
    }

    var body: some View {
        if isLoading && isEmpty {
            TrawlInitialLoadingView()
        } else if let error, isEmpty {
            ServiceErrorView(title: "Failed to Load", message: error, onRetry: onRetry)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isEmpty {
            let query = searchText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if query.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: emptyIcon)
                } description: {
                    if let emptyDescription {
                        Text(emptyDescription)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack(spacing: 0) {
                if let error {
                    ServiceErrorView(title: "Failed to Refresh", message: error, hasContent: true, onRetry: onRetry)
                }
                content
            }
        }
    }
}
