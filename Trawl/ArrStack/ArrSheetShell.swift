import SwiftUI

struct ArrSheetShell<Content: View>: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let subtitle: String?
    let confirmTitle: String?
    let isConfirmDisabled: Bool
    let isConfirmLoading: Bool
    let onConfirm: (() -> Void)?
    let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        confirmTitle: String? = nil,
        isConfirmDisabled: Bool = false,
        isConfirmLoading: Bool = false,
        onConfirm: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.confirmTitle = confirmTitle
        self.isConfirmDisabled = isConfirmDisabled
        self.isConfirmLoading = isConfirmLoading
        self.onConfirm = onConfirm
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(subtitle == nil ? title : "")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    if let subtitle {
                        ToolbarItem(placement: .principal) {
                            VStack(spacing: 0) {
                                Text(title)
                                    .font(.headline)
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
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
        .presentationDetents([.large])
    }
}
