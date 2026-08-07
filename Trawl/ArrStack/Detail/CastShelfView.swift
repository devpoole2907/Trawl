import SwiftUI

struct CastShelfView: View {
    let items: [CastShelfItem]
    var onSelect: ((CastShelfItem) -> Void)?

    init(items: [CastShelfItem], onSelect: ((CastShelfItem) -> Void)? = nil) {
        self.items = items
        self.onSelect = onSelect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Cast", systemImage: "person.2")
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.top, 10)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items) { item in
                        if onSelect != nil {
                            Button {
                                select(item)
                            } label: {
                                CastShelfCell(item: item)
                            }
                            .buttonStyle(.plain)
                        } else {
                            CastShelfCell(item: item)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            }
            .horizontalSoftEdges()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    private func select(_ item: CastShelfItem) {
        onSelect?(item)
    }
}

#if DEBUG
#Preview("Cast Shelf") {
    CastShelfView(items: [
        CastShelfItem(
            id: "preview-1",
            name: "Maya Chen",
            role: "Detective Rowan",
            profileURL: nil,
            destination: CastPersonRoute(personId: 1, fallbackName: "Maya Chen", fallbackProfileURL: nil)
        ),
        CastShelfItem(
            id: "preview-2",
            name: "Theo Williams",
            role: "Elias",
            profileURL: nil,
            destination: CastPersonRoute(personId: 2, fallbackName: "Theo Williams", fallbackProfileURL: nil)
        )
    ])
    .padding()
    .background(Color.black)
}
#endif
