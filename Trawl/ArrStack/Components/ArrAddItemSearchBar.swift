import SwiftUI

struct ArrAddItemSearchBar: View {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void
    
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
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
