//
//  QuickActionRunnerTests.swift
//  TrawlTests
//
//  Quick actions are the only place in Trawl where one tap acts on *every* connected
//  server at once - refresh both libraries, pause the whole queue, push Prowlarr's
//  indexers out. Two things about that are easy to get wrong and invisible when they
//  are: a server that cannot be reached must not abort the servers that can, and the
//  result must arrive as one line rather than as a stack of banners, one per service,
//  which is what a per-call report degenerates into on a dual-instance setup.
//
//  `perform` fires an unstructured `Task` with no seam to await, so the tests below
//  wait on the observable outcome using the target's established `awaitCondition`
//  idiom rather than sleeping.
//

import Foundation
import Testing
@testable import Trawl

@Suite("Quick action runner", .serialized)
@MainActor
struct QuickActionRunnerTests {

    // MARK: - The verbs themselves

    /// Cheap guard for the next action somebody adds: every case has to carry its own
    /// copy through four separate switches, and a case missed in one of them shows up
    /// as an empty banner rather than as a compiler error.
    @Test("Every quick action carries the copy the UI and its banner need")
    func everyActionIsFullyDescribed() {
        for action in NotificationQuickAction.allCases {
            #expect(!action.title.isEmpty, "\(action.rawValue) has no title.")
            #expect(!action.subtitle.isEmpty, "\(action.rawValue) has no subtitle.")
            #expect(!action.bannerTitle.isEmpty, "\(action.rawValue) has no banner title.")
            #expect(!action.successVerb.isEmpty, "\(action.rawValue) has no success verb.")
            #expect(!action.systemImage.isEmpty, "\(action.rawValue) has no symbol.")
        }
        let titles = NotificationQuickAction.allCases.map(\.title)
        #expect(Set(titles).count == titles.count, "Two actions share a title; the menu cannot tell them apart.")
    }

    @Test("An outcome keeps successes and failures apart, in the order they arrived")
    func outcomeRecordsBothSides() {
        var outcome = NotificationQuickActionOutcome()
        #expect(outcome.isEmpty)

        outcome.append(.succeeded("Sonarr"))
        outcome.append(.failed(target: "Radarr 4K", message: "The request timed out."))
        outcome.append(.succeeded("Radarr"))

        #expect(outcome.isEmpty == false)
        #expect(outcome.succeeded == ["Sonarr", "Radarr"])
        #expect(outcome.failures.map(\.target) == ["Radarr 4K"])
        #expect(outcome.failures.first?.message == "The request timed out.")
    }

    // MARK: - Fanning out

    /// Both servers reachable: one success banner naming both, and a real command
    /// posted to each. The names are the profiles' own, because with two Radarrs
    /// connected "Refreshed Radarr" would not say which one.
    @Test("Refresh Library reaches every connected server and reports them in one banner")
    func refreshLibraryFansOutAndSummarizesOnce() async throws {
        let hd = try await DualInstanceRadarrServer(label: "quick-hd", movies: "[]")
        let uhd = try await DualInstanceRadarrServer(label: "quick-4k", movies: "[]")
        defer { hd.stop(); uhd.stop() }

        try await withRadarrPair(hd: hd, uhd: uhd) { manager, center in
            let runner = makeRunner(arr: manager, center: center)
            runner.perform(.refreshLibrary)

            let reported = await awaitCondition { center.currentBanner != nil }
            #expect(reported, "The fan-out should report itself once every call has come back.")
            let banner = try #require(center.currentBanner)
            #expect(banner.title == "Refresh Library")
            #expect(banner.style == .success)
            #expect(banner.message == "Refreshed Radarr HD and Radarr 4K.")

            #expect(hd.commandBodies.count == 1)
            #expect(uhd.commandBodies.count == 1)
            #expect(hd.commandBodies.first?.contains("RefreshMovie") == true)
            #expect(uhd.commandBodies.first?.contains("RefreshMovie") == true)
            // The row is tappable again once the fan-out is done.
            #expect(center.runningQuickActions.contains(.refreshLibrary) == false)
        }
    }

    /// The regression this suite exists for. One server down must not stop the other
    /// from being refreshed, and the user must be told both halves at once - what
    /// worked and what did not - rather than a success banner replaced by an error
    /// banner a second later.
    @Test("An unreachable server fails beside the one that worked, in the same banner")
    func oneUnreachableServerDoesNotAbortTheFanOut() async throws {
        let hd = try await DualInstanceRadarrServer(label: "quick-alive", movies: "[]")
        let uhd = try await DualInstanceRadarrServer(label: "quick-dead", movies: "[]")
        defer { hd.stop() }

        try await withRadarrPair(hd: hd, uhd: uhd) { manager, center in
            // Connected, then gone - which is exactly how this fails in life: the
            // server answered when Trawl started and has since been rebooted.
            uhd.stop()

            let runner = makeRunner(arr: manager, center: center)
            runner.perform(.refreshLibrary)

            let reported = await awaitCondition { center.currentBanner != nil }
            #expect(reported, "A fan-out with one server down should still report.")
            let banner = try #require(center.currentBanner)
            #expect(banner.title == "Refresh Library")
            #expect(banner.style == .error, "A partial failure is an error banner, not a success one.")
            #expect(banner.message.contains("Refreshed Radarr HD"))
            #expect(banner.message.contains("Radarr 4K failed:"))
            // The reachable server was still refreshed.
            #expect(hd.commandBodies.count == 1)
        }
    }

    /// Nothing connected is its own answer. Silence here reads as a dead button.
    @Test("An action with nothing connected says so instead of doing nothing")
    func nothingConnectedIsReported() async throws {
        let center = InAppNotificationCenter()
        let runner = makeRunner(arr: ArrServiceManager(), center: center)

        runner.perform(.refreshLibrary)

        let reported = await awaitCondition { center.currentBanner != nil }
        #expect(reported, "An action with nothing to act on should still report.")
        let banner = try #require(center.currentBanner)
        #expect(banner.title == "Refresh Library")
        #expect(banner.style == .error)
        #expect(banner.message == "No connected service handled this command.")
    }

    /// The row spins and stops accepting taps while its action is in flight. Without
    /// the guard a double tap fans the whole thing out twice, which for Search All
    /// Missing means two full indexer sweeps.
    @Test("An action already running ignores a second tap")
    func aRunningActionIgnoresASecondTap() async throws {
        let hd = try await DualInstanceRadarrServer(label: "quick-guard", movies: "[]")
        defer { hd.stop() }

        try await withRadarr(hd) { manager, center in
            center.runningQuickActions.insert(.refreshLibrary)
            let runner = makeRunner(arr: manager, center: center)

            runner.perform(.refreshLibrary)

            // Nothing was sent and nothing was reported: the second tap is dropped
            // rather than queued behind the first.
            let sentSomething = await awaitCondition(maxYields: 200) { !hd.commandBodies.isEmpty }
            #expect(sentSomething == false, "A second tap while the action is in flight must not fan out again.")
            #expect(center.currentBanner == nil)
            #expect(center.runningQuickActions.contains(.refreshLibrary))
        }
    }

    // MARK: - Helpers

    private func makeRunner(
        arr: ArrServiceManager,
        center: InAppNotificationCenter
    ) -> QuickActionRunner {
        QuickActionRunner(
            arrServiceManager: arr,
            jellyfinServiceManager: JellyfinServiceManager(),
            sabnzbdServiceManager: SABnzbdServiceManager(),
            torrentService: TorrentService(
                apiClient: QBittorrentAPIClient(
                    baseURL: "http://127.0.0.1:1",
                    authService: AuthService(serverProfileID: UUID())
                )
            ),
            inAppNotificationCenter: center
        )
    }

    /// Waits for an unstructured `Task`'s observable result without sleeping, matching
    /// `BazarrViewModelTests.awaitCondition` and its neighbours.
    private func awaitCondition(maxYields: Int = 5_000, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<maxYields {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    private func withRadarrPair(
        hd: DualInstanceRadarrServer,
        uhd: DualInstanceRadarrServer,
        _ body: (ArrServiceManager, InAppNotificationCenter) async throws -> Void
    ) async throws {
        let manager = ArrServiceManager()
        let hdProfile = ArrServiceProfile(displayName: "Radarr HD", hostURL: hd.baseURL, serviceType: .radarr, qualityTier: .hd)
        let uhdProfile = ArrServiceProfile(displayName: "Radarr 4K", hostURL: uhd.baseURL, serviceType: .radarr, qualityTier: .uhd)
        for profile in [hdProfile, uhdProfile] {
            try await KeychainHelper.shared.save(key: profile.apiKeyKeychainKey, value: "quick-action-key")
        }
        defer {
            let keys = [hdProfile.apiKeyKeychainKey, uhdProfile.apiKeyKeychainKey]
            Task { for key in keys { try? await KeychainHelper.shared.delete(key: key) } }
        }

        await manager.connectService(hdProfile)
        await manager.connectService(uhdProfile)
        #expect(manager.connectedRadarr.count == 2)

        try await body(manager, InAppNotificationCenter())
        manager.showAllInstances(of: .radarr)
    }

    private func withRadarr(
        _ server: DualInstanceRadarrServer,
        _ body: (ArrServiceManager, InAppNotificationCenter) async throws -> Void
    ) async throws {
        let manager = ArrServiceManager()
        let profile = ArrServiceProfile(displayName: "Radarr HD", hostURL: server.baseURL, serviceType: .radarr, qualityTier: .hd)
        try await KeychainHelper.shared.save(key: profile.apiKeyKeychainKey, value: "quick-action-key")
        defer {
            let key = profile.apiKeyKeychainKey
            Task { try? await KeychainHelper.shared.delete(key: key) }
        }
        await manager.connectService(profile)
        try await body(manager, InAppNotificationCenter())
    }
}
