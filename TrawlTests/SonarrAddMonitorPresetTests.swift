import Testing
@testable import Trawl

/// The Add Series sheet's Monitor choices map to Sonarr's `addOptions.monitor`.
@Suite("Sonarr add monitor presets")
struct SonarrAddMonitorPresetTests {
    @Test("Choose Seasons sends skip, so the per-season switches are kept")
    func chooseSeasonsIsSkip() {
        // `none` would override the switches and unmonitor the whole series.
        #expect(SonarrAddMonitorPreset.chooseSeasons.apiValue == "skip")
    }

    @Test("Presets send Sonarr's own values")
    func presetValues() {
        #expect(SonarrAddMonitorPreset.all.apiValue == "all")
        #expect(SonarrAddMonitorPreset.future.apiValue == "future")
        #expect(SonarrAddMonitorPreset.missing.apiValue == "missing")
        #expect(SonarrAddMonitorPreset.existing.apiValue == "existing")
        #expect(SonarrAddMonitorPreset.firstSeason.apiValue == "firstSeason")
        #expect(SonarrAddMonitorPreset.lastSeason.apiValue == "lastSeason")
        #expect(SonarrAddMonitorPreset.pilot.apiValue == "pilot")
        #expect(SonarrAddMonitorPreset.none.apiValue == "none")
    }

    @Test("Series types send Sonarr's own values")
    func seriesTypes() {
        #expect(SonarrAddSeriesType.allCases.map(\.rawValue) == ["standard", "daily", "anime"])
    }
}
