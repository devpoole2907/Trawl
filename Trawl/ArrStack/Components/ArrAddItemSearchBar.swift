import SwiftUI

struct ArrAddItemSearchBar: View {
    @Binding var text: String
    let placeholder: String
    var onSubmit: () -> Void = {}
    
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            // A hint, not a label: macOS draws a field's title beside it, which would
            // repeat the text next to the magnifying glass.
            TextField("", text: $text, prompt: Text(placeholder))
                .labelsHidden()
                .textFieldStyle(.plain)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onSubmit {
                    onSubmit()
                }
        }
        .padding(10)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowBackground(Color.clear)
    }
}
