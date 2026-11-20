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
    let genres: [String]

    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    /// A short screen - a phone on its side, a folded iPhone Duo - puts the poster
    /// beside the title instead of above it. Stacked, the 240pt poster filled the
    /// whole first screen there, and Up Next (or a movie's search buttons) started
    /// below the fold on exactly the screens with the least room to scroll.
    private var isShortScreen: Bool {
        #if os(iOS)
        verticalSizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        if isShortScreen {
            HStack(alignment: .center, spacing: 18) {
                poster
                    .frame(width: 96, height: 144)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.5), radius: 16, y: 8)
                details(alignment: .leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        } else {
            VStack(spacing: 14) {
                poster
                    .frame(width: 160, height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.6), radius: 24, y: 10)
                details(alignment: .center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 16)
        }
    }

    private var poster: some View {
        ArrArtworkView(url: posterURL, contentMode: .fill) {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(iconColor.opacity(0.3))
                Image(systemName: iconName).font(.largeTitle).foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private func details(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 6) {
            Text(title)
                .font(.title2.bold())
                .foregroundStyle(.white)
                .multilineTextAlignment(alignment == .center ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
                .trawlCentralHeaderTitle(title)

            HStack(spacing: 4) {
                if let networkOrStudio, !networkOrStudio.isEmpty { Text(networkOrStudio) }
                if let year { Text("·"); Text(String(year)) }
                if let runtime, runtime > 0 { Text("·"); Text("\(runtime)m") }
            }
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.7))
            .lineLimit(1)
            .minimumScaleFactor(0.8)

            ArrDetailBadgeSection(badges: badges, isCentred: alignment == .center)

            if !genres.isEmpty {
                ArrDetailGenreChips(genres: genres, isCentred: alignment == .center)
                    .padding(.top, 2)
            }
        }
    }
}
