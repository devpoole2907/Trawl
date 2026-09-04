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
            // `Form`'s macOS default is the columns style, which draws a section header
            // as an ordinary row and a field's label beside the field. In a sheet this
            // narrow that put "Connection" inline against the paragraph above it and
            // pushed the address field's own label off the left edge. The grouped style
            // is the one System Settings uses: real headings, and a label column that
            // stays inside the sheet.
            #if os(macOS)
            .formStyle(.grouped)
            // A sheet with no intrinsic width shrink-wraps its narrowest row, so the
            // helper text under the fields was wrapping to four lines and clipping.
            // Height is deliberately left to the content: pinning it padded the short
            // sheets with a block of empty space above the button row.
            .frame(minWidth: 540, idealWidth: 580)
            #endif
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
            #if os(iOS)
            // Both describe a sheet that is dragged up from the bottom of a phone, which
            // is not what a Mac sheet is.
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            #endif
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
