import Testing
import Foundation
@testable import Trawl

/// Unit tests for the dependency-free pieces of the *arr App Intents layer:
/// safe add-default selection and the self-describing entity identifier codec.
@Suite("Arr Intent Support")
struct ArrIntentSupportTests {

    // MARK: - Quality profile defaults

    private func profile(id: Int, name: String) -> ArrQualityProfile {
        ArrQualityProfile(
            id: id, name: name, upgradeAllowed: nil, cutoff: nil, items: nil,
            minFormatScore: nil, cutoffFormatScore: nil, minUpgradeFormatScore: nil,
            formatItems: nil, language: nil
        )
    }

    @Test("Prefers a 1080p-style quality profile")
    func prefers1080() throws {
        let profiles = [
            profile(id: 1, name: "Any"),
            profile(id: 3, name: "HD-720p"),
            profile(id: 4, name: "HD-1080p"),
            profile(id: 5, name: "Ultra-HD")
        ]
        #expect(try ArrIntentSupport.defaultQualityProfileId(from: profiles) == 4)
    }

    @Test("Falls back to the first profile when no 1080p exists")
    func fallsBackToFirstProfile() throws {
        let profiles = [profile(id: 2, name: "SD"), profile(id: 5, name: "Ultra-HD")]
        #expect(try ArrIntentSupport.defaultQualityProfileId(from: profiles) == 2)
    }

    @Test("Throws when there are no quality profiles")
    func throwsWithoutProfiles() {
        #expect(throws: ArrIntentError.self) {
            _ = try ArrIntentSupport.defaultQualityProfileId(from: [])
        }
    }

    // MARK: - Root folder defaults

    private func folder(id: Int, path: String, accessible: Bool?) -> ArrRootFolder {
        ArrRootFolder(id: id, path: path, accessible: accessible, freeSpace: nil, totalSpace: nil)
    }

    @Test("Prefers an accessible root folder")
    func prefersAccessibleFolder() throws {
        let folders = [
            folder(id: 1, path: "/mnt/unavailable", accessible: false),
            folder(id: 2, path: "/data/Movies", accessible: true)
        ]
        #expect(try ArrIntentSupport.defaultRootFolderPath(from: folders) == "/data/Movies")
    }

    @Test("Falls back to the first folder when accessibility is unknown")
    func fallsBackToFirstFolder() throws {
        let folders = [
            folder(id: 1, path: "/data/A", accessible: nil),
            folder(id: 2, path: "/data/B", accessible: nil)
        ]
        #expect(try ArrIntentSupport.defaultRootFolderPath(from: folders) == "/data/A")
    }

    @Test("Throws when there are no root folders")
    func throwsWithoutFolders() {
        #expect(throws: ArrIntentError.self) {
            _ = try ArrIntentSupport.defaultRootFolderPath(from: [])
        }
    }

    // MARK: - Entity identifier codec

    @Test("Movie entity identifier round-trips through its query")
    func movieEntityRoundTrips() async throws {
        let payload = ArrMediaPayload(
            serviceID: UUID().uuidString,
            tmdbId: 693134,
            tvdbId: nil,
            libraryId: nil,
            title: "Dune: Part Two",
            titleSlug: "dune-part-two-693134",
            year: 2024,
            overview: "Paul Atreides unites with the Fremen.",
            monitored: true,
            hasFile: false
        )
        let entity = ArrMovieEntity(payload: payload)

        // The identifier alone must reconstruct an identical entity (cross-process safe).
        let restored = try await ArrMovieEntityQuery().entities(for: [entity.id])
        #expect(restored.count == 1)
        #expect(restored.first?.payload.tmdbId == 693134)
        #expect(restored.first?.payload.title == "Dune: Part Two")
        #expect(restored.first?.id == entity.id)
    }

    @Test("Series entity identifier round-trips through its query")
    func seriesEntityRoundTrips() async throws {
        let payload = ArrMediaPayload(
            serviceID: UUID().uuidString,
            tmdbId: nil,
            tvdbId: 371980,
            libraryId: 12,
            title: "Severance",
            titleSlug: "severance",
            year: 2022,
            overview: nil,
            monitored: true,
            hasFile: nil
        )
        let entity = ArrSeriesEntity(payload: payload)
        let restored = try await ArrSeriesEntityQuery().entities(for: [entity.id])
        #expect(restored.first?.payload.tvdbId == 371980)
        #expect(restored.first?.payload.libraryId == 12)
    }

    @Test("Invalid identifiers are dropped, not crashed on")
    func invalidIdentifierIsIgnored() async throws {
        let restored = try await ArrMovieEntityQuery().entities(for: ["not-base64-$$$"])
        #expect(restored.isEmpty)
    }

    @Test("A spoken library title resolves without requiring a catalog match")
    func libraryTitleEntityResolvesAnyNonEmptyTitle() async throws {
        let query = ArrLibraryTitleEntityQuery()
        let entities = try await query.entities(matching: "  Shrek the Third  ")

        #expect(entities.map(\.title) == ["Shrek the Third"])
        #expect(try await query.entities(matching: "   ").isEmpty)
        #expect(try await query.entities(for: ["Of Mice and Men"]).first?.title == "Of Mice and Men")
    }
}
