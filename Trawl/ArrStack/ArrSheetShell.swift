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
    let confirmPlacement: ConfirmPlacement
    let usesInlineLargeTitle: Bool

    /// Where the sheet's confirming action lives.
    ///
    /// A toolbar button is right for small edits, where the sheet is a detail the
    /// user is amending. For a sheet whose entire purpose is one commitment — add
    /// this series, add this download client — the action deserves the same weight
    /// the welcome flow gives it: a full-width capsule at the bottom, in thumb
    /// reach, rather than a word in the top corner.
    enum ConfirmPlacement {
        case toolbar
        case prominentBottom
    }
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
        confirmPlacement: ConfirmPlacement = .toolbar,
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
        self.confirmPlacement = confirmPlacement
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

                    if let confirmTitle, let onConfirm, confirmPlacement == .toolbar {
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
                .prominentBottomConfirm(
                    title: confirmPlacement == .prominentBottom ? confirmTitle : nil,
                    isLoading: isConfirmLoading,
                    isDisabled: isConfirmDisabled,
                    action: onConfirm
                )
        }
        .presentationDetents(detents)
        .presentationDragIndicator(dragIndicator)
    }
}

private extension View {
    @ViewBuilder
    func prominentBottomConfirm(
        title: String?,
        isLoading: Bool,
        isDisabled: Bool,
        action: (() -> Void)?
    ) -> some View {
        if let title, let action {
            prominentBottomButton(
                LocalizedStringKey(title),
                isLoading: isLoading,
                isDisabled: isDisabled,
                action: action
            )
        } else {
            self
        }
    }

    @ViewBuilder
    func appSheetNavigationSubtitle(_ subtitle: String?) -> some View {
        if let subtitle {
            self.navigationSubtitle(subtitle)
        } else {
            self
        }
    }
}
