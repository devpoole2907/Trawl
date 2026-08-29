import SwiftUI
import Observation

@Observable
@MainActor
final class CastPersonSheetViewModel {
    private(set) var person: TMDbPersonDetail?
    private(set) var credits: [TMDbPersonCredit] = []
    private(set) var isLoading = false
    var error: String?

    let personId: Int
    let fallbackName: String?
    let fallbackProfileURL: URL?

    private let client: TMDbClient

    init(route: CastPersonRoute, client: TMDbClient = TMDbClient()) {
        self.personId = route.personId
        self.fallbackName = route.fallbackName
        self.fallbackProfileURL = route.fallbackProfileURL
        self.client = client
    }

    #if DEBUG
    init(previewPerson: TMDbPersonDetail, credits: [TMDbPersonCredit]) {
        self.person = previewPerson
        self.credits = credits
        self.personId = previewPerson.id
        self.fallbackName = previewPerson.name
        self.fallbackProfileURL = previewPerson.profileURL()
        self.client = TMDbClient()
    }
    #endif

    func load() async {
        isLoading = true
        defer { isLoading = false }

        do {
            async let detailLoad = client.personDetail(personId: personId)
            async let creditsLoad = client.personCombinedCredits(personId: personId)
            let (detail, combinedCredits) = try await (detailLoad, creditsLoad)

            person = detail

            // Dedup by media type + id - cast and crew credits can reference the
            // same title (e.g. an actor who also directed), and a movie/tv id can
            // coincidentally collide across the two TMDb id namespaces.
            var seenIDs = Set<String>()
            let orderedCredits = (combinedCredits.cast ?? []) + (combinedCredits.crew ?? [])
            credits = orderedCredits.filter { credit in
                seenIDs.insert("\(credit.mediaType ?? "")-\(credit.id)").inserted
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct CastPersonRoute: Identifiable, Hashable {
    let personId: Int
    let fallbackName: String?
    let fallbackProfileURL: URL?

    var id: String { "person-\(personId)" }

    init(personId: Int, fallbackName: String?, fallbackProfileURL: URL?) {
        self.personId = personId
        self.fallbackName = fallbackName
        self.fallbackProfileURL = fallbackProfileURL
    }

    init(member: TMDbCastMember) {
        self.init(
            personId: member.id,
            fallbackName: member.name,
            fallbackProfileURL: member.profileURL()
        )
    }
}

struct CastPersonSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSelectCredit: ((TMDbPersonCredit) -> Void)?

    @State private var vm: CastPersonSheetViewModel

    init(route: CastPersonRoute, onSelectCredit: ((TMDbPersonCredit) -> Void)? = nil) {
        self.onSelectCredit = onSelectCredit
        self._vm = State(initialValue: CastPersonSheetViewModel(route: route))
    }

    #if DEBUG
    init(
        previewPerson: TMDbPersonDetail,
        credits: [TMDbPersonCredit],
        onSelectCredit: ((TMDbPersonCredit) -> Void)? = nil
    ) {
        self.onSelectCredit = onSelectCredit
        self._vm = State(initialValue: CastPersonSheetViewModel(previewPerson: previewPerson, credits: credits))
    }
    #endif

    var body: some View {
        NavigationStack {
            content
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            await vm.load()
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                biographySection

                filmographySection
            }
            .padding(16)
        }
        .navigationTitle(vm.person?.name ?? vm.fallbackName ?? "Cast")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Close", systemImage: "xmark") {
                    dismiss()
                }
                .labelStyle(.iconOnly)
            }
        }
    }

    private func selectCredit(_ credit: TMDbPersonCredit) {
        guard let onSelectCredit else { return }
        onSelectCredit(credit)
        dismiss()
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            ArrArtworkView(url: vm.person?.profileURL() ?? vm.fallbackProfileURL, contentMode: .fill) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "person.fill")
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: 96, height: 144)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            personIdentity

            Spacer()
        }
    }

    private var personIdentity: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(vm.person?.name ?? vm.fallbackName ?? "Unknown")
                .font(.title3.weight(.bold))

            if let department = vm.person?.knownForDepartment, !department.isEmpty {
                Label(department, systemImage: "sparkles")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let birthplace = vm.person?.placeOfBirth, !birthplace.isEmpty {
                Label(birthplace, systemImage: "mappin.and.ellipse")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var biographySection: some View {
        if let biography = vm.person?.biography, !biography.isEmpty {
            if shouldShowFullBiographyLink(for: biography) {
                NavigationLink {
                    BiographyDetailView(
                        title: vm.person?.name ?? vm.fallbackName ?? "Biography",
                        biography: biography
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Biography")
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Text(biography)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(5)
                            .multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Biography")
                        .font(.headline)
                    Text(biography)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var filmographySection: some View {
        if vm.isLoading && vm.credits.isEmpty {
            HStack {
                Spacer()
                ProgressView()
                Spacer()
            }
            .padding(.vertical, 20)
        } else if !vm.credits.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Label("Filmography", systemImage: "film.stack")
                    .font(.headline)
                    .foregroundStyle(.primary)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(vm.credits) { credit in
                            Button {
                                selectCredit(credit)
                            } label: {
                                filmographyCell(credit)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .horizontalSoftEdges()
            }
        }
    }

    private func filmographyCell(_ credit: TMDbPersonCredit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ArrArtworkView(url: credit.posterURL(), contentMode: .fill) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "film")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                    }
            }
            .frame(width: 100, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(credit.displayTitle)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.primary)

            if let year = credit.year {
                Text(year)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 100, alignment: .leading)
    }

    private func shouldShowFullBiographyLink(for biography: String) -> Bool {
        biography.count > 280 || biography.contains("\n")
    }
}

private struct BiographyDetailView: View {
    let title: String
    let biography: String

    var body: some View {
        ScrollView {
            Text(biography)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

#if DEBUG
#Preview("Cast Person") {
    CastPersonSheet(
        previewPerson: TMDbPersonDetail(
            id: 287,
            name: "Brad Pitt",
            biography: "An acclaimed actor and producer known for performances spanning character-driven dramas, thrillers, and large-scale studio films. His work has earned recognition both in front of and behind the camera.",
            birthday: "1963-12-18",
            deathday: nil,
            placeOfBirth: "Shawnee, Oklahoma, USA",
            knownForDepartment: "Acting",
            profilePath: nil
        ),
        credits: []
    )
}
#endif
