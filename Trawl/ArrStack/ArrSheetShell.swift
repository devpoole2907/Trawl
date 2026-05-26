import SwiftUI

typealias ArrSheetShell = AppSheetShell

struct AppSheetShell<Content: View>: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let subtitle: String?
    let cancelTitle: String
    let cancelSystemImage: String?
    let showsCancel: Bool
    let confirmTitle: String?
    let isConfirmDisabled: Bool
    let isConfirmLoading: Bool
    let onConfirm: (() -> Void)?
    let usesInlineLargeTitle: Bool
    let detents: Set<PresentationDetent>
    let dragIndicator: Visibility
    let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        cancelTitle: String = "Cancel",
        cancelSystemImage: String? = nil,
        showsCancel: Bool = true,
        confirmTitle: String? = nil,
        isConfirmDisabled: Bool = false,
        isConfirmLoading: Bool = false,
        onConfirm: (() -> Void)? = nil,
        usesInlineLargeTitle: Bool = false,
        detents: Set<PresentationDetent> = [.large],
        dragIndicator: Visibility = .hidden,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.cancelTitle = cancelTitle
        self.cancelSystemImage = cancelSystemImage
        self.showsCancel = showsCancel
        self.confirmTitle = confirmTitle
        self.isConfirmDisabled = isConfirmDisabled
        self.isConfirmLoading = isConfirmLoading
        self.onConfirm = onConfirm
        self.usesInlineLargeTitle = usesInlineLargeTitle
        self.detents = detents
        self.dragIndicator = dragIndicator
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .appSheetNavigationSubtitle(subtitle)
                #if os(iOS)
                .toolbarTitleDisplayMode(usesInlineLargeTitle ? ToolbarTitleDisplayMode.inlineLarge : ToolbarTitleDisplayMode.inline)
                #endif
                .toolbar {
                    if showsCancel {
                        ToolbarItem(placement: .cancellationAction) {
                            Button {
                                dismiss()
                            } label: {
                                if let cancelSystemImage {
                                    Label(cancelTitle, systemImage: cancelSystemImage)
                                        .labelStyle(.iconOnly)
                                } else {
                                    Text(cancelTitle)
                                }
                            }
                        }
                    }

                    if let confirmTitle, let onConfirm {
                        ToolbarItem(placement: .confirmationAction) {
                            if isConfirmLoading {
                                ProgressView()
                            } else {
                                Button(confirmTitle, action: onConfirm)
                                    .disabled(isConfirmDisabled)
                            }
                        }
                    }
                }
        }
        .presentationDetents(detents)
        .presentationDragIndicator(dragIndicator)
    }
}

private extension View {
    @ViewBuilder
    func appSheetNavigationSubtitle(_ subtitle: String?) -> some View {
        if let subtitle {
            self.navigationSubtitle(subtitle)
        } else {
            self
        }
    }
}
