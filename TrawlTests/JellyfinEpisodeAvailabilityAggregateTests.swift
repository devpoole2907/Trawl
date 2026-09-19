import Foundation
import Testing
@testable import Trawl

@Suite("Jellyfin episode availability aggregation")
@MainActor
struct JellyfinEpisodeAvailabilityAggregateTests {
    @Test("An episode present only in the second matching Jellyfin series is still present")
    func episodeCanComeFromSecondSeriesCopy() throws {
        let defaultCopy = try Self.items(
            #"{"Items":[{"Id":"default-e2","Name":"Episode 2","Type":"Episode","IndexNumber":2,"ParentIndexNumber":29}],"TotalRecordCount":1}"#
        )
        let fourKCopy = try Self.items(
            #"{"Items":[{"Id":"4k-e1","Name":"Episode 1","Type":"Episode","IndexNumber":1,"ParentIndexNumber":29}],"TotalRecordCount":1}"#
        )

        let match = JellyfinEpisodeAvailabilityAggregate.matchingEpisode(
            in: [.resolved(defaultCopy), .resolved(fourKCopy)],
            seasonNumber: 29,
            episodeNumber: 1
        )

        #expect(match?.id == "4k-e1")
    }

    @Test("Episode counts union matching Jellyfin series without double-counting copies")
    func countsLogicalEpisodesAcrossCopies() throws {
        let defaultCopy = try Self.items(
            #"{"Items":[{"Id":"a1","Type":"Episode","IndexNumber":1,"ParentIndexNumber":1},{"Id":"a2","Type":"Episode","IndexNumber":2,"ParentIndexNumber":1},{"Id":"special","Type":"Episode","IndexNumber":1,"ParentIndexNumber":0}],"TotalRecordCount":3}"#
        )
        let fourKCopy = try Self.items(
            #"{"Items":[{"Id":"b1","Type":"Episode","IndexNumber":1,"ParentIndexNumber":1},{"Id":"b3","Type":"Episode","IndexNumber":3,"ParentIndexNumber":1}],"TotalRecordCount":2}"#
        )

        let count = JellyfinEpisodeAvailabilityAggregate.uniqueNonSpecialEpisodeCount(
            in: [.resolved(defaultCopy), .resolved(fourKCopy)]
        )

        #expect(count == 3)
    }

    @Test("A partial aggregate stays unsettled instead of reporting a misleading count")
    func partialAggregateDoesNotClaimACompleteCount() throws {
        let resolved = try Self.items(
            #"{"Items":[{"Id":"a1","Type":"Episode","IndexNumber":1,"ParentIndexNumber":1}],"TotalRecordCount":1}"#
        )
        let states: [JellyfinAvailabilityResolver.State] = [.resolved(resolved), .loading]

        #expect(JellyfinEpisodeAvailabilityAggregate.uniqueNonSpecialEpisodeCount(in: states) == nil)
        #expect(JellyfinEpisodeAvailabilityAggregate.isLoading(states))
    }

    private static func items(_ json: String) throws -> [JellyfinLibraryItem] {
        try JSONDecoder().decode(JellyfinItemsResponse.self, from: Data(json.utf8)).items
    }
}
