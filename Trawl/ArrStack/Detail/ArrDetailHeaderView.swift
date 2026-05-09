import SwiftUI

struct ArrDetailHeaderView: View {
    let title: String
    let posterURL: URL?
    let iconName: String // "tv" or "film"
    let iconColor: Color // .purple or .orange
    let networkOrStudio: String?
    let year: Int?
    let runtime: Int?
    let badges: [ArrDetailBadge]

    var body: some View {
        VStack(spacing: 14) {
            ArrArtworkView(url: posterURL, contentMode: .fill) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16).fill(iconColor.opacity(0.3))
                    Image(systemName: iconName).font(.largeTitle).foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: 160, height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.6), radius: 24, y: 10)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 4) {
                    if let networkOrStudio, !networkOrStudio.isEmpty { Text(networkOrStudio) }
                    if let year { Text("·"); Text(String(year)) }
                    if let runtime, runtime > 0 { Text("·"); Text("\(runtime)m") }
                }
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .minimumScaleFactor(0.8)

                ArrDetailBadgeSection(badges: badges)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
    }
}
