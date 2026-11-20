//
//  SonarrUpNextCard.swift
//  Trawl
//
//  The newest episode of a series, and the one thing to do about it.
//

import SwiftUI

/// Sits under the title on Series detail so the most common visit - "is this week's
/// episode here yet, and if not, find it" - needs no scrolling and no drilling into a
/// season. It used to take five taps and two scrolls.
///
/// Says nothing when there is nothing to say: an ended show with every episode on
/// disk, or a series whose episodes have not loaded.
struct SonarrUpNextCard<EpisodeDestination: View>: View {
    let latest: SonarrEpisode?
    let next: SonarrEpisode?
    let latestState: SonarrEpisodeState?
    /// Quality of the file on disk, when there is one.
    let qualityName: String?
    let isSearching: Bool
    let isUpdatingMonitor: Bool
    let onSearch: (SonarrEpisode) -> Void
    let onPickRelease: (SonarrEpisode) -> Void
    let onMonitor: (SonarrEpisode) -> Void
    @ViewBuilder let episodeDestination: (SonarrEpisode) -> EpisodeDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let latest, let latestState {
                NavigationLink {
                    episodeDestination(latest)
                } label: {
                    header(for: latest, state: latestState)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("series-up-next-episode")

                actions(for: latest, state: latestState)
            } else if let next {
                nextOnlyHeader(next)
            }

            if let next, latest != nil {
                Label {
                    Text("Next: \(next.episodeIdentifier) · \(Self.relativeAirDate(next))")
                } icon: {
                    Image(systemName: "calendar")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("series-up-next-next")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 20)
                .fill(LinearGradient(
                    colors: [Color.purple.opacity(0.32), Color.purple.opacity(0.06)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Color.purple.opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("series-up-next")
    }

    // MARK: Header

    private func header(for episode: SonarrEpisode, state: SonarrEpisodeState) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Latest · \(episode.episodeIdentifier) · \(Self.relativeAirDate(episode))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(episode.title ?? "Episode \(episode.episodeNumber)")
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                SonarrEpisodeStateBadge(state: state, qualityName: qualityName)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .contentShape(Rectangle())
    }

    private func nextOnlyHeader(_ episode: SonarrEpisode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Up Next · \(episode.episodeIdentifier)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text("Airs \(Self.relativeAirDate(episode))")
                .font(.headline)
            if let title = episode.title, !title.isEmpty, title != "TBA" {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("series-up-next-next")
    }

    // MARK: Actions

    @ViewBuilder
    private func actions(for episode: SonarrEpisode, state: SonarrEpisodeState) -> some View {
        switch state {
        case .missing, .unmonitored:
            VStack(spacing: 8) {
                Button {
                    onSearch(episode)
                } label: {
                    HStack(spacing: 8) {
                        if isSearching {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "magnifyingglass")
                        }
                        Text("Search for \(episode.episodeIdentifier)")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .tint(.purple)
                .disabled(isSearching)
                .accessibilityIdentifier("series-up-next-search")

                HStack(spacing: 8) {
                    Button {
                        onPickRelease(episode)
                    } label: {
                        Label("Pick Release", systemImage: "person.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("series-up-next-pick-release")

                    if state == .unmonitored {
                        Button {
                            onMonitor(episode)
                        } label: {
                            HStack(spacing: 6) {
                                if isUpdatingMonitor {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "bookmark")
                                }
                                Text("Monitor")
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.glass)
                        .disabled(isUpdatingMonitor)
                        .accessibilityIdentifier("series-up-next-monitor")
                    }
                }

                if state == .unmonitored {
                    Text("Not monitored, so Sonarr won't grab this on its own.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: progress)
                    .tint(.purple)
                Text(progress > 0 ? "\(Int((progress * 100).rounded()))% downloaded" : "Queued")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .importIssue:
            Text("Downloaded but couldn't be imported. The Import Issues card below has the fix.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .onDisk, .notAired:
            EmptyView()
        }
    }

    // MARK: Dates

    /// "Today", "Yesterday", "Wed", or "19 Nov" - whichever is shortest and still
    /// unambiguous. Within a week either side the weekday is what people say.
    static func relativeAirDate(_ episode: SonarrEpisode, now: Date = .now, calendar: Calendar = .current) -> String {
        guard let date = SonarrEpisodeProgress.airDate(of: episode) else { return "TBA" }
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if calendar.isDateInTomorrow(date) { return String(localized: "Tomorrow") }
        let days = abs(calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 99)
        if days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return sameYear
            ? date.formatted(.dateTime.day().month(.abbreviated))
            : date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

/// A small capsule naming an episode's state, shared by Up Next and the episode rows
/// so the two never describe the same episode differently.
struct SonarrEpisodeStateBadge: View {
    let state: SonarrEpisodeState
    var qualityName: String?

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.18), in: Capsule())
            .accessibilityIdentifier("episode-state-\(identifier)")
    }

    private var title: String {
        switch state {
        case .onDisk:
            if let qualityName, !qualityName.isEmpty { return String(localized: "On Disk · \(qualityName)") }
            return String(localized: "On Disk")
        case .downloading(let progress):
            return progress > 0 ? String(localized: "Downloading · \(Int((progress * 100).rounded()))%") : String(localized: "Queued")
        case .importIssue: return String(localized: "Import Issue")
        case .missing: return String(localized: "Missing")
        case .unmonitored: return String(localized: "Missing · Not Monitored")
        case .notAired: return String(localized: "Not Aired")
        }
    }

    private var systemImage: String {
        switch state {
        case .onDisk: "checkmark.circle.fill"
        case .downloading: "arrow.down.circle.fill"
        case .importIssue: "exclamationmark.triangle.fill"
        case .missing: "magnifyingglass.circle.fill"
        case .unmonitored: "bookmark.slash.fill"
        case .notAired: "clock"
        }
    }

    private var tint: Color {
        switch state {
        case .onDisk: .green
        case .downloading: .purple
        case .importIssue: .orange
        case .missing: .orange
        case .unmonitored: .secondary
        case .notAired: .secondary
        }
    }

    private var identifier: String {
        switch state {
        case .onDisk: "on-disk"
        case .downloading: "downloading"
        case .importIssue: "import-issue"
        case .missing: "missing"
        case .unmonitored: "unmonitored"
        case .notAired: "not-aired"
        }
    }
}
