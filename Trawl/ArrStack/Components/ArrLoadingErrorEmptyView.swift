import SwiftUI

struct ArrLoadingErrorEmptyView<Content: View>: View {
    let isLoading: Bool
    let error: String?
    let isEmpty: Bool
    let emptyTitle: LocalizedStringKey
    let emptyIcon: String
    let emptyDescription: LocalizedStringKey?
    let onRetry: (() async -> Void)?
    let content: Content

    init(
        isLoading: Bool,
        error: String?,
        isEmpty: Bool,
        emptyTitle: LocalizedStringKey,
        emptyIcon: String,
        emptyDescription: LocalizedStringKey?,
        onRetry: (() async -> Void)?,
        @ViewBuilder content: () -> Content
    ) {
        self.isLoading = isLoading
        self.error = error
        self.isEmpty = isEmpty
        self.emptyTitle = emptyTitle
        self.emptyIcon = emptyIcon
        self.emptyDescription = emptyDescription
        self.onRetry = onRetry
        self.content = content()
    }

    var body: some View {
        if isLoading && isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error, isEmpty {
            ContentUnavailableView {
                Label("Failed to Load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                if let onRetry {
                    Button("Retry") { Task { await onRetry() } }
                }
            }
        } else if isEmpty {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: emptyIcon)
            } description: {
                if let emptyDescription {
                    Text(emptyDescription)
                }
            }
        } else {
            content
        }
    }
}
