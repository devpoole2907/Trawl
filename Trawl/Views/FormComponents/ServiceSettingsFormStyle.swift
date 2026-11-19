import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ServiceSettingsFormStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            #if os(macOS)
            .formStyle(.grouped)
            #endif
    }
}

extension View {
    func serviceSettingsFormStyle() -> some View {
        modifier(ServiceSettingsFormStyle())
    }
}

/// Styles a `TextField`/`SecureField` that lives inside a `LabeledContent` row.
///
/// The two platforms want opposite things. iOS treats the field's title as a placeholder
/// and reads best with the value trailing, opposite its label. macOS draws that title as a
/// real leading label - which would double up with the row's own label - and its fields
/// read leading-aligned like every other Mac form.
extension View {
    func labeledContentField() -> some View {
        #if os(macOS)
        labelsHidden()
            .multilineTextAlignment(.leading)
        #else
        multilineTextAlignment(.trailing)
        #endif
    }
}

extension View {
    /// Applies `.searchable` only where the navigation bar is the right home for it.
    ///
    /// Size class is intentional: an open iPhone Duo is still a phone, but its regular
    /// inner canvas has room for the same inline search treatment as an iPad sheet.
    func navigationBarSearchable(text: Binding<String>, prompt: String) -> some View {
        modifier(NavigationBarSearchableModifier(text: text, prompt: prompt))
    }
}

private struct NavigationBarSearchableModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let text: Binding<String>
    let prompt: String

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            content.searchable(text: text, prompt: prompt)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension View {
    /// Sizes a macOS sheet that is presented directly rather than through `AppSheetShell`.
    ///
    /// A Mac sheet takes its size from its content. A `Form` self-sizes, but a `List` or
    /// `ScrollView` has no intrinsic height, so a sheet wrapping one collapses to a sliver.
    /// Shell-based sheets state this with `minContentHeight`; this is the equivalent for a
    /// bare `NavigationStack` in a `.sheet`.
    func macSheetSizing(
        minWidth: CGFloat = 540,
        idealWidth: CGFloat = 580,
        minHeight: CGFloat = 520
    ) -> some View {
        #if os(macOS)
        frame(minWidth: minWidth, idealWidth: idealWidth, minHeight: minHeight)
        #else
        self
        #endif
    }
}

/// Shared chrome for existing configuration: read-only → Edit → draft → Save.
/// The owner snapshots/restores its draft and exits editing only after an accepted save.
struct TrawlEditToolbar: ToolbarContent {
    @Binding var isEditing: Bool
    let isSaving: Bool
    let canSave: Bool
    var canEdit: Bool = true
    var editTitle: String = "Edit"
    var saveTitle: String = "Save"
    var onEdit: () -> Void = {}
    let onCancel: () -> Void
    let onSave: () -> Void
    var onClose: (() -> Void)? = nil

    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            if isEditing {
                Button("Cancel", systemImage: "xmark") {
                    onCancel()
                    isEditing = false
                }
                .disabled(isSaving)
            } else if let onClose {
                Button("Close", systemImage: "xmark", action: onClose)
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            if isSaving {
                ProgressView()
                    .accessibilityLabel("Saving")
            } else if isEditing {
                Button(saveTitle, systemImage: "checkmark", action: onSave)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!canSave)
            } else {
                Button(editTitle, systemImage: "pencil") {
                    onEdit()
                    isEditing = true
                }
                .disabled(!canEdit)
            }
        }
    }
}

extension View {
    /// Keep the draft on screen until Save succeeds or Cancel explicitly restores it.
    func trawlEditingGuard(isEditing: Bool, isSaving: Bool) -> some View {
        navigationBarBackButtonHidden(isEditing || isSaving)
            .interactiveDismissDisabled(isEditing || isSaving)
    }
}
