import SwiftUI

struct CastShelfCell: View {
    let item: CastShelfItem

    var body: some View {
        VStack(spacing: 4) {
            portrait

            VStack(spacing: 1) {
                Text(item.name)
                    .font(.caption)
                    .lineLimit(2)

                if let role = item.role {
                    Text(role)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .multilineTextAlignment(.center)
            .frame(width: 76, alignment: .top)
        }
        .frame(width: 76, alignment: .top)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var portrait: some View {
        ArrArtworkView(url: item.profileURL, contentMode: .fill) {
            Circle()
                .fill(.quaternary)
                .overlay {
                    Image(systemName: "person.fill")
                        .foregroundStyle(.secondary)
                }
        }
        .frame(width: 56, height: 56)
        .clipShape(Circle())
    }

    private var accessibilityLabel: String {
        guard let role = item.role else { return item.name }
        return "\(item.name), as \(role)"
    }
}

#if DEBUG
#Preview("Cast Shelf Cell") {
    CastShelfCell(
        item: CastShelfItem(
            id: "preview-1",
            name: "Maya Chen",
            role: "Detective Rowan",
            profileURL: nil,
            destination: CastPersonRoute(personId: 1, fallbackName: "Maya Chen", fallbackProfileURL: nil)
        )
    )
    .padding()
    .background(Color.black)
}
#endif
