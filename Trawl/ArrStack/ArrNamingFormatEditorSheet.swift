import Foundation
import SwiftUI

struct ArrNamingFormatEditorSheet: View {
    let target: ArrNamingFormatEditorTarget
    let onSave: (String) -> Void

    @State private var localFormat: String
    @State private var tokenFilter = ""
    @State private var showSaveAlert = false
    @Environment(\.dismiss) private var dismiss

    init(target: ArrNamingFormatEditorTarget, initialFormat: String, onSave: @escaping (String) -> Void) {
        self.target = target
        self.onSave = onSave
        self._localFormat = State(initialValue: initialFormat)
    }

    private var accent: Color { target.serviceType.serviceIdentity.brandColor }

    private var filteredTokenGroups: [ArrNamingTokenGroup] {
        let query = tokenFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return target.tokenGroups }

        return target.tokenGroups.compactMap { group in
            let tokens = group.tokens.filter { $0.matches(query) }
            guard !tokens.isEmpty else { return nil }
            return ArrNamingTokenGroup(title: group.title, tokens: tokens)
        }
    }

    private var preview: String {
        ArrNamingFormatPreview.preview(for: localFormat, groups: target.tokenGroups)
    }

    var body: some View {
        ArrSheetShell(
            title: target.title,
            subtitle: target.serviceType.displayName,
            cancelTitle: "Cancel",
            confirmTitle: "Save",
            onConfirm: { showSaveAlert = true },
            detents: [.medium, .large],
            dragIndicator: .visible
        ) {
            Form {
                Section("Format") {
                    TextField("Naming format", text: $localFormat, axis: .vertical)
                        .lineLimit(2...6)
                        .font(.body.monospaced())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Button {
                        localFormat = ""
                    } label: {
                        Label("Clear Format", systemImage: "xmark.circle")
                    }
                    .disabled(localFormat.isEmpty)
                }

                Section("Preview") {
                    Text(preview)
                        .font(.callout.monospaced())
                        .foregroundStyle(localFormat.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !target.presets.isEmpty {
                    Section("Presets") {
                        ForEach(target.presets) { preset in
                            Button {
                                localFormat = preset.format
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(preset.title)
                                        .font(.subheadline)
                                        .foregroundStyle(.primary)
                                    Text(preset.format)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .padding(.vertical, 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if filteredTokenGroups.isEmpty {
                    ContentUnavailableView(
                        "No Tokens",
                        systemImage: "magnifyingglass",
                        description: Text("Try another search.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(filteredTokenGroups) { group in
                        Section(group.title) {
                            ArrNamingTokenFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                                ForEach(group.tokens) { token in
                                    tokenButton(token)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .searchable(text: $tokenFilter, prompt: "Find tokens")
        }
        .alert("Save Format?", isPresented: $showSaveAlert) {
            Button("Save") {
                onSave(localFormat)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Apply this naming format to \(target.serviceType.displayName)?")
        }
    }

    private func tokenButton(_ token: ArrNamingToken) -> some View {
        Button {
            insert(token.value)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: token.systemImage)
                    .font(.caption)
                    .foregroundStyle(accent)
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 2) {
                    Text(token.title)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                    Text(token.value)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium))
            .overlay {
                RoundedRectangle(cornerRadius: DesignConstants.CornerRadius.medium)
                    .stroke(accent.opacity(0.24), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Inserts \(token.value)")
    }

    private func insert(_ value: String) {
        guard !localFormat.isEmpty else {
            localFormat = value
            return
        }

        let trailingCharacters = CharacterSet(charactersIn: " -._/[(")
        if let lastScalar = localFormat.unicodeScalars.last,
           trailingCharacters.contains(lastScalar) {
            localFormat += value
        } else {
            localFormat += " " + value
        }
    }
}

enum ArrNamingFormatEditorTarget: Identifiable, Hashable {
    case sonarr(ArrNamingSonarrFormatField)
    case radarr(ArrNamingRadarrFormatField)

    var id: String {
        switch self {
        case .sonarr(let field): "sonarr-\(field.rawValue)"
        case .radarr(let field): "radarr-\(field.rawValue)"
        }
    }

    var serviceType: ArrServiceType {
        switch self {
        case .sonarr: .sonarr
        case .radarr: .radarr
        }
    }

    var title: String {
        switch self {
        case .sonarr(let field): field.title
        case .radarr(let field): field.title
        }
    }

    var tokenGroups: [ArrNamingTokenGroup] {
        switch self {
        case .sonarr(let field): field.tokenGroups
        case .radarr(let field): field.tokenGroups
        }
    }

    var presets: [ArrNamingFormatPreset] {
        switch self {
        case .sonarr(let field): field.presets
        case .radarr(let field): field.presets
        }
    }
}

enum ArrNamingSonarrFormatField: String, Hashable {
    case standardEpisode
    case dailyEpisode
    case animeEpisode
    case seriesFolder
    case seasonFolder
    case specialsFolder

    var title: String {
        switch self {
        case .standardEpisode: "Standard Episode Format"
        case .dailyEpisode: "Daily Episode Format"
        case .animeEpisode: "Anime Episode Format"
        case .seriesFolder: "Series Folder Format"
        case .seasonFolder: "Season Folder Format"
        case .specialsFolder: "Specials Folder Format"
        }
    }

    var rowTitle: String {
        switch self {
        case .standardEpisode: "Standard"
        case .dailyEpisode: "Daily"
        case .animeEpisode: "Anime"
        case .seriesFolder: "Series"
        case .seasonFolder: "Season"
        case .specialsFolder: "Specials"
        }
    }

    func value(in config: SonarrNamingConfig) -> String? {
        switch self {
        case .standardEpisode: config.standardEpisodeFormat
        case .dailyEpisode: config.dailyEpisodeFormat
        case .animeEpisode: config.animeEpisodeFormat
        case .seriesFolder: config.seriesFolderFormat
        case .seasonFolder: config.seasonFolderFormat
        case .specialsFolder: config.specialsFolderFormat
        }
    }

    func setValue(_ value: String, in config: inout SonarrNamingConfig) {
        switch self {
        case .standardEpisode: config.standardEpisodeFormat = value
        case .dailyEpisode: config.dailyEpisodeFormat = value
        case .animeEpisode: config.animeEpisodeFormat = value
        case .seriesFolder: config.seriesFolderFormat = value
        case .seasonFolder: config.seasonFolderFormat = value
        case .specialsFolder: config.specialsFolderFormat = value
        }
    }

    var tokenGroups: [ArrNamingTokenGroup] {
        switch self {
        case .standardEpisode:
            ArrNamingTokenCatalog.sonarrEpisodeGroups(includeDaily: true, includeAbsolute: false)
        case .dailyEpisode:
            ArrNamingTokenCatalog.sonarrEpisodeGroups(includeDaily: true, includeAbsolute: false)
        case .animeEpisode:
            ArrNamingTokenCatalog.sonarrEpisodeGroups(includeDaily: true, includeAbsolute: true)
        case .seriesFolder:
            ArrNamingTokenCatalog.sonarrSeriesFolderGroups
        case .seasonFolder, .specialsFolder:
            ArrNamingTokenCatalog.sonarrSeasonFolderGroups
        }
    }

    var presets: [ArrNamingFormatPreset] {
        switch self {
        case .standardEpisode:
            [
                .init(title: "Balanced", format: "{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle} {Quality Full}"),
                .init(title: "Compact", format: "{Series CleanTitle} - S{season:00}E{episode:00} - {Episode CleanTitle}"),
                .init(title: "With Media Info", format: "{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle} {Quality Full} {MediaInfo Simple}")
            ]
        case .dailyEpisode:
            [
                .init(title: "Balanced", format: "{Series TitleYear} - {Air-Date} - {Episode CleanTitle} {Quality Full}"),
                .init(title: "Compact", format: "{Series CleanTitle} - {Air-Date} - {Episode CleanTitle}"),
                .init(title: "With Release Group", format: "{Series TitleYear} - {Air-Date} - {Episode CleanTitle} {Quality Full} {-Release Group}")
            ]
        case .animeEpisode:
            [
                .init(title: "Absolute", format: "{Series TitleYear} - {absolute:000} - {Episode CleanTitle} {Quality Full}"),
                .init(title: "Season Episode", format: "{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle} {Quality Full}"),
                .init(title: "Absolute With Group", format: "{Series TitleYear} - {absolute:000} - {Episode CleanTitle} {Quality Full} {-Release Group}")
            ]
        case .seriesFolder:
            [
                .init(title: "Title and Year", format: "{Series TitleYear}"),
                .init(title: "Title Only", format: "{Series Title}"),
                .init(title: "Grouped by Letter", format: "{Series TitleFirstCharacter}/{Series TitleYear}")
            ]
        case .seasonFolder:
            [
                .init(title: "Padded Season", format: "Season {season:00}"),
                .init(title: "Season", format: "Season {Season}")
            ]
        case .specialsFolder:
            [
                .init(title: "Specials", format: "Specials"),
                .init(title: "Season 00", format: "Season 00")
            ]
        }
    }
}

enum ArrNamingRadarrFormatField: String, Hashable {
    case standardMovie
    case movieFolder

    var title: String {
        switch self {
        case .standardMovie: "Movie File Format"
        case .movieFolder: "Movie Folder Format"
        }
    }

    var rowTitle: String {
        switch self {
        case .standardMovie: "Standard"
        case .movieFolder: "Folder"
        }
    }

    func value(in config: RadarrNamingConfig) -> String? {
        switch self {
        case .standardMovie: config.standardMovieFormat
        case .movieFolder: config.movieFolderFormat
        }
    }

    func setValue(_ value: String, in config: inout RadarrNamingConfig) {
        switch self {
        case .standardMovie: config.standardMovieFormat = value
        case .movieFolder: config.movieFolderFormat = value
        }
    }

    var tokenGroups: [ArrNamingTokenGroup] {
        switch self {
        case .standardMovie:
            ArrNamingTokenCatalog.radarrMovieFileGroups
        case .movieFolder:
            ArrNamingTokenCatalog.radarrMovieFolderGroups
        }
    }

    var presets: [ArrNamingFormatPreset] {
        switch self {
        case .standardMovie:
            [
                .init(title: "Balanced", format: "{Movie Title} ({Release Year}) {Quality Full}"),
                .init(title: "With Media Info", format: "{Movie Title} ({Release Year}) {Quality Full} {MediaInfo Simple}"),
                .init(title: "With Edition", format: "{Movie Title} ({Release Year}) {Edition Tags} {Quality Full}")
            ]
        case .movieFolder:
            [
                .init(title: "Title and Year", format: "{Movie Title} ({Release Year})"),
                .init(title: "Title Only", format: "{Movie Title}"),
                .init(title: "Grouped by Collection", format: "{Movie Collection}/{Movie Title} ({Release Year})")
            ]
        }
    }
}

struct ArrNamingTokenGroup: Identifiable, Hashable {
    let title: String
    let tokens: [ArrNamingToken]

    var id: String { title }
}

struct ArrNamingToken: Identifiable, Hashable {
    let title: String
    let value: String
    let sample: String
    let systemImage: String

    var id: String { value }

    func matches(_ query: String) -> Bool {
        let lowercasedQuery = query.lowercased()
        return title.lowercased().contains(lowercasedQuery)
            || value.lowercased().contains(lowercasedQuery)
            || sample.lowercased().contains(lowercasedQuery)
    }
}

struct ArrNamingFormatPreset: Identifiable, Hashable {
    let title: String
    let format: String

    var id: String { title + format }
}

enum ArrNamingTokenCatalog {
    static func sonarrEpisodeGroups(includeDaily: Bool, includeAbsolute: Bool) -> [ArrNamingTokenGroup] {
        var episodeTokens = [
            token("SxxExx", "S{season:00}E{episode:00}", "S02E03", "number.square"),
            token("Season", "{Season}", "2", "number"),
            token("Season 00", "{season:00}", "02", "number"),
            token("Episode", "{Episode}", "3", "number"),
            token("Episode 00", "{episode:00}", "03", "number"),
            token("Episode Title", "{Episode Title}", "Pilot", "quote.bubble"),
            token("Clean Episode Title", "{Episode CleanTitle}", "Pilot", "wand.and.stars")
        ]

        if includeDaily {
            episodeTokens.append(contentsOf: [
                token("Air Date", "{Air Date}", "2026 05 17", "calendar"),
                token("Air-Date", "{Air-Date}", "2026-05-17", "calendar")
            ])
        }

        if includeAbsolute {
            episodeTokens.append(contentsOf: [
                token("Absolute", "{Absolute}", "42", "number"),
                token("Absolute 000", "{absolute:000}", "042", "number")
            ])
        }

        return [
            .init(title: "Series", tokens: sonarrSeriesTokens),
            .init(title: "Episode", tokens: episodeTokens),
            .init(title: "Quality", tokens: sharedQualityTokens),
            .init(title: "Media Info", tokens: sharedMediaInfoTokens),
            .init(title: "Release", tokens: sonarrReleaseTokens)
        ]
    }

    static var sonarrSeriesFolderGroups: [ArrNamingTokenGroup] {
        [
            .init(title: "Series", tokens: sonarrSeriesTokens)
        ]
    }

    static var sonarrSeasonFolderGroups: [ArrNamingTokenGroup] {
        [
            .init(title: "Series", tokens: sonarrSeriesTokens),
            .init(title: "Season", tokens: [
                token("Season", "{Season}", "2", "number"),
                token("Season 00", "{season:00}", "02", "number")
            ])
        ]
    }

    static var radarrMovieFileGroups: [ArrNamingTokenGroup] {
        [
            .init(title: "Movie", tokens: radarrMovieTokens),
            .init(title: "Quality", tokens: sharedQualityTokens),
            .init(title: "Media Info", tokens: sharedMediaInfoTokens + [
                token("3D", "{MediaInfo 3D}", "3D", "view.3d")
            ]),
            .init(title: "Release", tokens: radarrReleaseTokens)
        ]
    }

    static var radarrMovieFolderGroups: [ArrNamingTokenGroup] {
        [
            .init(title: "Movie", tokens: radarrMovieTokens)
        ]
    }

    private static let sonarrSeriesTokens = [
        token("Series TitleYear", "{Series TitleYear}", "Example Show (2026)", "tv"),
        token("Series Title", "{Series Title}", "Example Show", "textformat"),
        token("Series CleanTitle", "{Series CleanTitle}", "Example.Show", "wand.and.stars"),
        token("Series TitleThe", "{Series TitleThe}", "Example Show, The", "textformat.abc"),
        token("Series First Letter", "{Series TitleFirstCharacter}", "E", "character.cursor.ibeam"),
        token("Series Year", "{Series Year}", "2026", "calendar"),
        token("TVDb ID", "{TvdbId}", "12345", "number"),
        token("TVMaze ID", "{TvMazeId}", "54321", "number"),
        token("TMDb ID", "{TmdbId}", "67890", "number"),
        token("IMDb ID", "{ImdbId}", "tt1234567", "number")
    ]

    private static let radarrMovieTokens = [
        token("Movie Title", "{Movie Title}", "Example Movie", "film"),
        token("Movie CleanTitle", "{Movie CleanTitle}", "Example.Movie", "wand.and.stars"),
        token("Movie TitleThe", "{Movie TitleThe}", "Example Movie, The", "textformat.abc"),
        token("Movie First Letter", "{Movie TitleFirstCharacter}", "E", "character.cursor.ibeam"),
        token("Original Title", "{Movie OriginalTitle}", "Original Example", "text.quote"),
        token("Clean Original Title", "{Movie CleanOriginalTitle}", "Original.Example", "wand.and.stars"),
        token("Release Year", "{Release Year}", "2026", "calendar"),
        token("Certification", "{Movie Certification}", "PG-13", "checkmark.seal"),
        token("Collection", "{Movie Collection}", "Example Collection", "rectangle.stack"),
        token("Collection The", "{Movie CollectionThe}", "Example Collection, The", "rectangle.stack"),
        token("TMDb ID", "{TmdbId}", "67890", "number"),
        token("IMDb ID", "{ImdbId}", "tt1234567", "number")
    ]

    private static let sharedQualityTokens = [
        token("Quality Full", "{Quality Full}", "WEBDL-1080p Proper", "sparkles.tv"),
        token("Quality Title", "{Quality Title}", "WEBDL-1080p", "sparkles.tv"),
        token("Quality Proper", "{Quality Proper}", "Proper", "checkmark.seal"),
        token("Quality Real", "{Quality Real}", "REAL", "checkmark.seal"),
        token("Custom Formats", "{Custom Formats}", "HDR10 Atmos", "tag"),
        token("Custom Format", "{Custom Format}", "HDR10", "tag")
    ]

    private static let sharedMediaInfoTokens = [
        token("Media Simple", "{MediaInfo Simple}", "x265 EAC3", "info.circle"),
        token("Media Full", "{MediaInfo Full}", "x265 EAC3[EN]", "info.circle"),
        token("Video Codec", "{MediaInfo VideoCodec}", "x265", "video"),
        token("Video Bit Depth", "{MediaInfo VideoBitDepth}", "10", "eyedropper"),
        token("Dynamic Range", "{MediaInfo VideoDynamicRange}", "HDR10", "sun.max"),
        token("Dynamic Range Type", "{MediaInfo VideoDynamicRangeType}", "HDR", "sun.max"),
        token("Audio Codec", "{MediaInfo AudioCodec}", "EAC3", "waveform"),
        token("Audio Channels", "{MediaInfo AudioChannels}", "5.1", "speaker.wave.3"),
        token("Audio Languages", "{MediaInfo AudioLanguages}", "[EN]", "globe"),
        token("Subtitle Languages", "{MediaInfo SubtitleLanguages}", "[EN]", "captions.bubble")
    ]

    private static let sonarrReleaseTokens = [
        token("Original Title", "{Original Title}", "Example.Show.S02E03.1080p-GROUP", "text.quote"),
        token("Original Filename", "{Original Filename}", "example.show.s02e03", "doc"),
        token("Release Group", "{Release Group}", "GROUP", "person.2"),
        token("Release Group Optional", "{-Release Group}", "-GROUP", "person.2"),
        token("Release Hash", "{Release Hash}", "ABC123", "number")
    ]

    private static let radarrReleaseTokens = [
        token("Edition Tags", "{Edition Tags}", "Directors Cut", "tag"),
        token("Original Title", "{Original Title}", "Example.Movie.2026.1080p-GROUP", "text.quote"),
        token("Original Filename", "{Original Filename}", "example.movie.2026", "doc"),
        token("Release Group", "{Release Group}", "GROUP", "person.2"),
        token("Release Group Optional", "{-Release Group}", "-GROUP", "person.2")
    ]

    private static func token(_ title: String, _ value: String, _ sample: String, _ systemImage: String) -> ArrNamingToken {
        ArrNamingToken(title: title, value: value, sample: sample, systemImage: systemImage)
    }
}

enum ArrNamingFormatPreview {
    static func preview(for format: String, groups: [ArrNamingTokenGroup]) -> String {
        let trimmedFormat = format.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFormat.isEmpty else { return "No format yet" }

        let tokens = groups
            .flatMap(\.tokens)
            .sorted { $0.value.count > $1.value.count }

        var output = trimmedFormat
        for token in tokens {
            output = output.replacingOccurrences(
                of: NSRegularExpression.escapedPattern(for: token.value),
                with: token.sample,
                options: [.regularExpression, .caseInsensitive]
            )
        }

        return output
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ArrNamingTokenFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let proposedWidth = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        guard proposedWidth > 0 else { return .zero }

        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > proposedWidth {
                y += rowHeight + verticalSpacing
                x = 0
                rowHeight = 0
            }

            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }

        return CGSize(width: proposedWidth, height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += rowHeight + verticalSpacing
                x = bounds.minX
                rowHeight = 0
            }

            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#if DEBUG
#Preview("Naming Format Editor - Episode") {
    ArrNamingFormatEditorSheet(
        target: .sonarr(.standardEpisode),
        initialFormat: SonarrNamingConfig.preview.standardEpisodeFormat ?? ""
    ) { _ in }
}

#Preview("Naming Format Editor - Movie") {
    ArrNamingFormatEditorSheet(
        target: .radarr(.standardMovie),
        initialFormat: RadarrNamingConfig.preview.standardMovieFormat ?? ""
    ) { _ in }
}
#endif
