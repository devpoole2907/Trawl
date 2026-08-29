import SwiftUI

/// The media behind a request, presented the way Sonarr and Radarr present theirs
/// - same shell, same hero, same overview card, same cast shelf - with the
/// request's own facts and the approve/decline decision added on top.
///
/// It reuses `ArrItemDetailView` and friends rather than hand-rolling artwork and
/// a cast strip: those components already exist for the Arr detail screens, and a
/// second implementation would mean every future change to that look had to be
/// made twice.
///
/// The media detail is fetched rather than passed in. A request payload carries
/// only a title, a poster path and a TMDb id - enough to label a row, nowhere near
/// enough to judge on.
struct SeerrRequestDetailView: View {
    let request: SeerrMediaRequest
    var onApprove: (() -> Void)?
    var onDecline: (() -> Void)?
    var onDelete: (() -> Void)?

    @Environment(SeerrServiceManager.self) private var seerrServiceManager
    @Environment(ArrServiceManager.self) private var arrServiceManager
    @Environment(SyncService.self) private var syncService
    @Environment(\.dismiss) private var dismiss

    @State private var detail: SeerrMediaDetail?
    @State private var isLoadingDetail = false
    @State private var detailError: String?
    @State private var selectedCastMember: CastPersonRoute?
    /// Picking a credit inside the person sheet can't push while the sheet is up,
    /// so it's held and resolved on dismiss - the same handoff the Arr detail
    /// screens use.
    @State private var pendingCastCredit: TMDbPersonCredit?
    @State private var castCreditMovie: RadarrMovie?
    @State private var castCreditSeries: SonarrSeries?
    @State private var isDeleteConfirmationPresented = false

    private var media: SeerrRequestMedia? { request.media }
    private var isPending: Bool { request.requestStatus == .pending }
    private var isSeries: Bool { media?.mediaType == "tv" }
    private var title: String { detail?.displayTitle ?? media?.displayTitle ?? "Unknown Media" }
    private var posterURL: URL? { detail?.posterURL ?? media?.posterURL }

    var body: some View {
        ArrItemDetailView(
            item: request,
            title: title,
            backgroundURL: detail?.backdropURL ?? posterURL
        ) { _ in
            ScrollView {
                VStack(alignment: .center, spacing: 20) {
                    hero
                    cards
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 44)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
        }
        .task { await loadDetail() }
        .sheet(item: $selectedCastMember, onDismiss: completeCastCreditNavigation) { route in
            CastPersonSheet(route: route, onSelectCredit: { pendingCastCredit = $0 })
        }
        .navigationDestination(item: $castCreditMovie) { creditMovie in
            RadarrMovieDetailView(
                movie: creditMovie,
                viewModel: RadarrViewModel(serviceManager: arrServiceManager)
            )
            .environment(syncService)
        }
        .navigationDestination(item: $castCreditSeries) { creditSeries in
            SonarrSeriesDetailView(
                series: creditSeries,
                viewModel: SonarrViewModel(serviceManager: arrServiceManager)
            )
            .environment(syncService)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        ArrDetailHeaderView(
            title: title,
            posterURL: posterURL,
            iconName: isSeries ? "tv" : "film",
            iconColor: isSeries ? .purple : .orange,
            networkOrStudio: media?.typeLabel,
            year: detail?.yearText.flatMap(Int.init),
            runtime: detail?.runtimeMinutes,
            badges: badges,
            genres: detail?.genreNames ?? []
        )
    }

    /// Reuses the Arr badge row so a Seerr request reads the same as a movie or
    /// series does: status first, then the qualifiers.
    private var badges: [ArrDetailBadge] {
        var badges: [ArrDetailBadge] = []

        if let badge = request.badgeStatus {
            badges.append(ArrDetailBadge(
                icon: badgeIcon(for: badge),
                label: badge.title,
                color: badge.statusColor
            ))
        }
        if request.is4k == true {
            badges.append(ArrDetailBadge(icon: "4k.tv", label: "4K", color: .indigo))
        }
        if let rating = detail?.ratingText {
            badges.append(ArrDetailBadge(icon: "star.fill", label: rating, color: .yellow))
        }
        if let seasons = detail?.seasonsText {
            badges.append(ArrDetailBadge(icon: "rectangle.stack", label: seasons, color: .secondary))
        }

        return badges
    }

    private func badgeIcon(for status: SeerrRequestBadgeStatus) -> String {
        switch status {
        case .pending:
            "clock"
        case .declined, .failed:
            "xmark.circle"
        case .processing:
            "arrow.trianglehead.2.clockwise.rotate.90"
        case .partiallyAvailable:
            "circle.lefthalf.filled"
        case .approved, .available, .completed:
            "checkmark.circle"
        }
    }

    // MARK: - Cards

    @ViewBuilder
    private var cards: some View {
        if isPending, onApprove != nil || onDecline != nil {
            decisionCard
        }

        if let overview = detail?.overview, !overview.isEmpty {
            ArrDetailOverviewCard(text: overview)
        }

        if let cast = detail?.credits?.cast, !cast.isEmpty {
            CastShelfView(
                items: cast.prefix(20).map(Self.castShelfItem),
                onSelect: { selectedCastMember = $0.destination }
            )
        }

        requestCard

        if isLoadingDetail {
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading details…")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
        } else if let detailError {
            VStack(spacing: 4) {
                Text("Details Unavailable")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(detailError)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, 12)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
        }

        if let onDelete {
            Button(role: .destructive) {
                isDeleteConfirmationPresented = true
            } label: {
                Label("Delete Request", systemImage: "trash")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16))
            .confirmationDialog(
                "Delete Request?",
                isPresented: $isDeleteConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    onDelete()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes the request from Seerr.")
            }
        }
    }

    private var decisionCard: some View {
        HStack(spacing: 12) {
            if let onApprove {
                decisionButton(
                    title: "Approve",
                    systemImage: "checkmark.circle.fill",
                    tint: .green
                ) {
                    onApprove()
                    dismiss()
                }
            }
            if let onDecline {
                decisionButton(
                    title: "Decline",
                    systemImage: "xmark.circle.fill",
                    tint: .orange
                ) {
                    onDecline()
                    dismiss()
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func decisionButton(
        title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 16))
    }

    private var requestCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Request", systemImage: "square.and.arrow.down")
                .font(.headline)
                .foregroundStyle(.white)

            ForEach(requestFacts, id: \.label) { fact in
                HStack(alignment: .top) {
                    Text(fact.label)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer(minLength: 12)
                    Text(fact.value)
                        .font(.subheadline)
                        .foregroundStyle(fact.color ?? .white)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
    }

    private struct RequestFact {
        let label: String
        let value: String
        var color: Color?
    }

    private var requestFacts: [RequestFact] {
        var facts: [RequestFact] = []

        if let badge = request.badgeStatus {
            facts.append(RequestFact(label: "Status", value: badge.title, color: badge.statusColor))
        }
        facts.append(RequestFact(label: "Type", value: media?.typeLabel ?? "Media"))
        if let requester = request.requestedBy?.displayName, !requester.isEmpty {
            facts.append(RequestFact(label: "Requested by", value: requester))
        }
        if let requested = Self.formattedDate(request.createdAt) {
            facts.append(RequestFact(label: "Requested", value: requested))
        }
        if let updated = Self.formattedDate(request.updatedAt),
           updated != Self.formattedDate(request.createdAt) {
            facts.append(RequestFact(label: "Updated", value: updated))
        }
        if let rootFolder = request.rootFolder, !rootFolder.isEmpty {
            facts.append(RequestFact(label: "Root folder", value: rootFolder))
        }

        return facts
    }

    // MARK: - Cast bridging

    /// Seerr proxies TMDb but re-serialises it in camelCase, so `TMDbCastMember`
    /// can't decode this payload directly. The shelf's own item type is the shared
    /// seam instead - same cell, same person sheet, different decode.
    private static func castShelfItem(_ member: SeerrCastMember) -> CastShelfItem {
        let personID = member.id ?? 0
        return CastShelfItem(
            id: "seerr-\(personID)-\(member.character ?? "no-role")",
            name: member.name ?? "Unknown",
            role: member.character,
            profileURL: member.profileURL,
            destination: CastPersonRoute(
                personId: personID,
                fallbackName: member.name,
                fallbackProfileURL: member.profileURL
            )
        )
    }

    /// Resolves the tapped credit into something Trawl can actually show. Seerr has
    /// no standalone media screen, so a credit lands on the Radarr or Sonarr detail
    /// via the shared lookup - the same resolver and failure message the Arr detail
    /// screens use, rather than a second way of doing it.
    private func completeCastCreditNavigation() {
        guard let credit = pendingCastCredit else { return }
        pendingCastCredit = nil

        Task {
            let resolver = ArrMediaLookupResolver(serviceManager: arrServiceManager)
            if credit.isMovie {
                if let resolved = await resolver.resolveMovie(tmdbId: credit.id) {
                    castCreditMovie = resolved
                } else {
                    InAppNotificationCenter.shared.showError(
                        title: "Couldn't Open Title",
                        message: "Radarr couldn't find \"\(credit.displayTitle)\"."
                    )
                }
            } else {
                if let resolved = await resolver.resolveSeries(tmdbId: credit.id) {
                    castCreditSeries = resolved
                } else {
                    InAppNotificationCenter.shared.showError(
                        title: "Couldn't Open Title",
                        message: "Sonarr couldn't find \"\(credit.displayTitle)\"."
                    )
                }
            }
        }
    }

    // MARK: - Loading

    private func loadDetail() async {
        guard detail == nil, !isLoadingDetail else { return }
        guard let tmdbId = media?.tmdbId, let client = seerrServiceManager.activeClient else {
            // No TMDb id means Seerr never resolved the media. The request's own
            // facts still render; there's simply nothing richer to fetch.
            return
        }

        isLoadingDetail = true
        detailError = nil
        defer { isLoadingDetail = false }

        do {
            detail = try await client.getMediaDetail(
                tmdbId: tmdbId,
                mediaType: media?.mediaType ?? "movie"
            )
        } catch {
            detailError = error.localizedDescription
        }
    }

    private static func formattedDate(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
            return nil
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
