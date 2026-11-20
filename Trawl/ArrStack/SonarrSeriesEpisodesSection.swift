//
//  SonarrSeriesEpisodesSection.swift
//  Trawl
//
//  Series detail's Episodes: a season picker with that season's episodes under it.
//

import SwiftUI

/// Replaces one full-width card per season. A 27-season show was five screens of
/// near-identical "10 of 10 episodes" cards, and every episode was a further push
/// away. This stays one short section however many seasons a show has, opens on the
/// season holding the newest episode, and marks the seasons with gaps so they can be
/// found without opening each one.
struct SonarrSeriesEpisodesSection<SeasonDestination: View>: View {
    @Bindable var viewModel: SonarrViewModel
    let series: SonarrSeries?
    let seasonNumbers: [Int]
    let episodes: [SonarrEpisode]
    let bazarrEpisodes: [BazarrEpisode]
    let bazarrClient: BazarrAPIClient?
    let onBazarrEpisodeUpdated: (BazarrEpisode?) -> Void
    let isSearchingSeason: Bool
    let onSearchSeason: (_ seasonNumber: Int, _ episodeCount: Int) -> Void
    let onPickSeasonRelease: (_ seasonNumber: Int) -> Void
    @ViewBuilder let seasonDestination: (_ seasonNumber: Int) -> SeasonDestination

    /// Nil until the user picks one; until then the section follows the newest
    /// episode, so a season that starts airing while the screen is open is the one
    /// shown rather than whatever was newest when it appeared.
    @State private var pickedSeason: Int?

    private var now: Date { .now }

    private var selectedSeason: Int? {
        if let pickedSeason, seasonNumbers.contains(pickedSeason) { return pickedSeason }
        return SonarrEpisodeProgress.defaultSeason(seasonNumbers: seasonNumbers, episodes: episodes, now: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Episodes", systemImage: "list.bullet.rectangle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let totals {
                    Text("\(totals.onDisk) of \(totals.aired) aired")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 4)

            if seasonNumbers.count > 1 {
                seasonStrip
            }

            if let season = selectedSeason {
                seasonCard(season)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("series-episodes")
    }

    private var totals: SonarrEpisodeProgress.SeasonCounts? {
        guard !episodes.isEmpty else { return nil }
        return SonarrEpisodeProgress.seasonCounts(episodes.filter { $0.seasonNumber > 0 }, now: now)
    }

    // MARK: Season strip

    private var seasonStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(seasonNumbers, id: \.self) { number in
                        seasonChip(number)
                            .id(number)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .onAppear {
                if let selectedSeason { proxy.scrollTo(selectedSeason, anchor: .leading) }
            }
            .onChange(of: selectedSeason) { _, season in
                guard let season else { return }
                withAnimation { proxy.scrollTo(season, anchor: .center) }
            }
        }
    }

    private func seasonChip(_ number: Int) -> some View {
        let isSelected = number == selectedSeason
        let counts = counts(for: number)
        return Button {
            pickedSeason = number
        } label: {
            Text(number == 0 ? "Specials" : "S\(number)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .foregroundStyle(isSelected ? Color.black : Color.primary)
                .background {
                    Capsule().fill(isSelected ? Color.white : Color.clear)
                }
                .glassEffect(isSelected ? .identity : .regular.interactive(), in: Capsule())
                .overlay(alignment: .topTrailing) {
                    if let counts, counts.missing > 0 {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 8, height: 8)
                            .offset(x: 1, y: -1)
                            .accessibilityHidden(true)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(chipAccessibilityLabel(number, counts: counts))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("series-season-chip-\(number)")
    }

    private func chipAccessibilityLabel(_ number: Int, counts: SonarrEpisodeProgress.SeasonCounts?) -> String {
        let name = number == 0 ? String(localized: "Specials") : String(localized: "Season \(number)")
        guard let counts, counts.missing > 0 else { return name }
        return String(localized: "\(name), \(counts.missing) missing")
    }

    // MARK: Season card

    private func seasonEpisodes(_ season: Int) -> [SonarrEpisode] {
        episodes.filter { $0.seasonNumber == season }
    }

    private func counts(for season: Int) -> SonarrEpisodeProgress.SeasonCounts? {
        let list = seasonEpisodes(season)
        if !list.isEmpty { return SonarrEpisodeProgress.seasonCounts(list, now: now) }
        // Episodes not loaded yet: Sonarr's own statistics, which already leave
        // unaired episodes out of `episodeCount`.
        guard let stats = series?.seasons?.first(where: { $0.seasonNumber == season })?.statistics else { return nil }
        let aired = stats.episodeCount ?? 0
        return .init(onDisk: stats.episodeFileCount ?? 0, aired: aired, upcoming: max(0, (stats.totalEpisodeCount ?? aired) - aired))
    }

    private func seasonCard(_ season: Int) -> some View {
        // Newest first: the reason to open this section is nearly always the most
        // recent episode, and in a long season it was the last row of the list.
        let list = seasonEpisodes(season).sorted { $0.episodeNumber > $1.episodeNumber }
        let counts = counts(for: season)
        return VStack(spacing: 0) {
            NavigationLink {
                seasonDestination(season)
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(season == 0 ? "Specials" : "Season \(season)")
                            .font(.subheadline.weight(.semibold))
                        if let counts {
                            Text(Self.summary(counts))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    Text("Season Details")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("series-season-details-\(season)")

            Divider().padding(.leading, 14)

            if list.isEmpty {
                HStack {
                    if viewModel.isLoadingEpisodes {
                        ProgressView().controlSize(.small)
                        Text("Loading episodes…")
                    } else {
                        Text("No episodes listed for this season.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            } else {
                ForEach(list) { episode in
                    SonarrSeasonEpisodeRow(
                        viewModel: viewModel,
                        series: series,
                        episode: episode,
                        bazarrEpisodes: bazarrEpisodes,
                        bazarrClient: bazarrClient,
                        isLast: episode.id == list.last?.id,
                        formattedDate: Self.formattedDate,
                        onBazarrEpisodeUpdated: onBazarrEpisodeUpdated
                    )
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    onSearchSeason(season, list.count)
                } label: {
                    HStack(spacing: 6) {
                        if isSearchingSeason {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "magnifyingglass")
                        }
                        Text("Search Season")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.glass)
                .disabled(isSearchingSeason)
                .accessibilityIdentifier("series-season-search")

                Button {
                    onPickSeasonRelease(season)
                } label: {
                    Label("Pick Release", systemImage: "person.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("series-season-pick-release")
            }
            .padding(10)
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: season)
    }

    static func summary(_ counts: SonarrEpisodeProgress.SeasonCounts) -> String {
        var parts: [String] = []
        if counts.aired > 0 {
            parts.append(String(localized: "\(counts.onDisk) of \(counts.aired) aired"))
        }
        if counts.missing > 0 {
            parts.append(String(localized: "\(counts.missing) missing"))
        }
        if counts.upcoming > 0 {
            parts.append(String(localized: "\(counts.upcoming) to come"))
        }
        return parts.isEmpty ? String(localized: "No episodes yet") : parts.joined(separator: " · ")
    }

    private static func formattedDate(_ string: String?) -> String {
        guard let string, !string.isEmpty else { return "TBA" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: string) else { return string }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
