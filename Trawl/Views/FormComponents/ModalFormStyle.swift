import SwiftUI

struct ModalFormStyle: ViewModifier {
    let title: String
    let primaryTitle: String
    var isPrimaryDisabled: Bool = false
    var isSaving: Bool = false
    let primaryAction: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    
    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button(primaryTitle, action: primaryAction)
                            .disabled(isPrimaryDisabled)
                            .fontWeight(.semibold)
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
    }
}

extension View {
    func modalFormStyle(
        title: String,
        primaryTitle: String,
        isPrimaryDisabled: Bool = false,
        isSaving: Bool = false,
        primaryAction: @escaping () -> Void
    ) -> some View {
        modifier(ModalFormStyle(
            title: title,
            primaryTitle: primaryTitle,
            isPrimaryDisabled: isPrimaryDisabled,
            isSaving: isSaving,
            primaryAction: primaryAction
        ))
    }
}
