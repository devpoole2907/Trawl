import SwiftUI

struct ServerURLField: View {
    @Binding var url: String
    /// What the field is for, phrased as an example address - "Jellyfin URL (e.g.
    /// http://192.168.1.50:8096)". On iOS this is the placeholder, sitting inside the
    /// field where a long string reads fine.
    var title: String = "Server address"
    /// The Mac's leading-column label. macOS draws a form field's label *beside* the
    /// field rather than inside it, so `title` there becomes a column heading wide
    /// enough to push the field off the sheet. This short label goes in the column and
    /// `title` moves into the field as its prompt, which is what it always read as.
    var macLabel: String = "Server Address"

    var body: some View {
        field
            #if os(iOS)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .textContentType(.URL)
            #endif
            .autocorrectionDisabled()
    }

    @ViewBuilder
    private var field: some View {
        #if os(macOS)
        TextField(macLabel, text: $url, prompt: Text(title))
        #else
        TextField(title, text: $url)
        #endif
    }
}
