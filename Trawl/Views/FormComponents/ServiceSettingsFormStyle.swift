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

/// Where a sheet's search field belongs.
///
/// An iPhone sheet has a navigation bar and the room to devote a row to `.searchable`.
/// iPad and Mac sheets are wider and shallower, so search rides in the segment bar
/// alongside the filters instead - and on the Mac `.searchable` has no bar to live in
/// at all, so it lands on top of the sheet's own title.
var usesNavigationBarSearch: Bool {
    #if os(iOS)
    UIDevice.current.userInterfaceIdiom == .phone
    #else
    false
    #endif
}

extension View {
    /// Applies `.searchable` only where the navigation bar is the right home for it.
    @ViewBuilder
    func navigationBarSearchable(text: Binding<String>, prompt: String) -> some View {
        #if os(iOS)
        if usesNavigationBarSearch {
            searchable(text: text, prompt: prompt)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
