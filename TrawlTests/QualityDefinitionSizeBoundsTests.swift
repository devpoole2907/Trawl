import Foundation
import Testing
@testable import Trawl

/// The rules behind the quality definition editor's bar and wheel. They decide what
/// is PUT to Sonarr or Radarr, and the server rejects - or silently stores - a
/// definition whose minimum exceeds its maximum, so each rule is pinned here rather
/// than trusted to the UI that happens to call it.
@Suite("Quality definition size bounds")
@MainActor
struct QualityDefinitionSizeBoundsTests {
    private func definition(min: Double?, preferred: Double?, max: Double?) -> ArrQualityDefinition {
        ArrQualityDefinition(
            id: 1,
            quality: ArrQuality(id: 7, name: "WEBDL-1080p", source: "web", resolution: 1080),
            title: "WEBDL-1080p",
            weight: 70,
            minSize: min,
            maxSize: max,
            preferredSize: preferred
        )
    }

    @Test("Raising the minimum past the maximum carries the maximum and preferred with it")
    func minimumPushesMaximumUp() {
        var value = definition(min: 10, preferred: 30, max: 50)
        value.setMinSize(60)
        #expect(value.minSize == 60)
        #expect(value.maxSize == 60)
        #expect(value.preferredSize == 60)
    }

    @Test("An unlimited maximum is not dragged up by a larger minimum")
    func minimumLeavesUnlimitedMaximumAlone() {
        var value = definition(min: 5, preferred: 3, max: 0)
        value.setMinSize(20)
        #expect(value.minSize == 20)
        #expect(value.maxSize == 0, "0 means unlimited; turning it into 20 would cap every release.")
        #expect(value.preferredSize == 20, "Preferred cannot sit below the minimum.")
    }

    @Test("Lowering the maximum under the minimum pulls the minimum and preferred down")
    func maximumPullsMinimumDown() {
        var value = definition(min: 40, preferred: 60, max: 100)
        value.setMaxSize(30)
        #expect(value.minSize == 30)
        #expect(value.maxSize == 30)
        #expect(value.preferredSize == 30)
    }

    @Test("Setting the maximum to unlimited keeps the minimum and stops capping preferred")
    func unlimitedMaximumReleasesPreferred() {
        var value = definition(min: 40, preferred: 90, max: 100)
        value.setMaxSize(0)
        #expect(value.minSize == 40)
        #expect(value.maxSize == 0)
        #expect(value.preferredSize == 90)
    }

    @Test("A preferred size inside the range is left exactly where it was")
    func preferredInsideRangeIsUntouched() {
        var value = definition(min: 10, preferred: 25, max: 50)
        value.clampPreferredSize()
        #expect(value.preferredSize == 25)
    }

    @Test("A definition with no preferred size keeps having none")
    func missingPreferredStaysMissing() {
        var value = definition(min: 10, preferred: nil, max: 50)
        value.setMinSize(20)
        #expect(value.preferredSize == nil, "Clamping must not invent a preference the server never had.")
    }

    @Test("Normalising for the server resolves an inverted range at the maximum")
    func normaliseInvertedRange() {
        var value = definition(min: 200, preferred: 150, max: 100)
        value.normalizeSizeBoundsForServer()
        #expect(value.minSize == 100)
        #expect(value.maxSize == 100)
        #expect(value.preferredSize == 100)
    }

    @Test("Normalising leaves a minimum alone when the maximum is unlimited")
    func normaliseWithUnlimitedMaximum() {
        var value = definition(min: 200, preferred: 50, max: 0)
        value.normalizeSizeBoundsForServer()
        #expect(value.minSize == 200)
        #expect(value.maxSize == 0)
        #expect(value.preferredSize == 200)
    }
}
