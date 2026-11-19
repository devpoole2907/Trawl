//
//  SetupCheckBrowserStateTests.swift
//  TrawlTests
//
//  The Setup Check's list and detail columns are two instances of one screen that
//  share this state, so what it selects is what both columns agree the user is
//  looking at. It is also the only thing standing between an empty audit and an
//  "all clear" about services that were never checked. All of it is a pure
//  function of findings and configuration, so none of it needs a server.
//

import Foundation
import Testing
@testable import Trawl

@Suite("Setup Check browser state")
@MainActor
struct SetupCheckBrowserStateTests {

    /// Each fixture a different kind of fault, so every one has its own id:
    /// `ConfigurationIssue.id` is built from the fault and its subject, and two
    /// findings sharing both would collapse into a single row.
    private static func finding(
        _ kind: ConfigurationIssueKind,
        _ severity: ConfigurationIssueSeverity,
        on server: String = "Radarr HD"
    ) -> ConfigurationIssue {
        ConfigurationIssue(
            kind: kind,
            severity: severity,
            subject: ConfigurationIssueSubject(serviceType: .radarr, displayName: server),
            title: "\(kind.rawValue) on \(server)",
            detail: "",
            fix: .manual(guidance: "")
        )
    }

    /// A mixed result, in the order the store actually holds it.
    private static var mixed: [ConfigurationIssue] {
        [
            finding(.downloadClientElsewhere, .note),
            finding(.configurationUnavailable, .unknown),
            finding(.noDownloadClient, .problem),
            finding(.noRootFolder, .problem, on: "Radarr 4K")
        ].displayOrdered
    }

    // MARK: Filtering

    @Test("The filters partition findings by severity, losing and doubling none")
    func filtersPartitionBySeverity() {
        let issues = Self.mixed
        let problems = SetupCheckFilter.problems.filter(issues: issues)
        let unverified = SetupCheckFilter.unverified.filter(issues: issues)
        let notes = SetupCheckFilter.notes.filter(issues: issues)

        #expect(SetupCheckFilter.all.filter(issues: issues) == issues)
        #expect(problems.allSatisfy { $0.severity == .problem })
        #expect(unverified.allSatisfy { $0.severity == .unknown })
        #expect(notes.allSatisfy { $0.severity == .note })
        #expect(problems.count == 2)
        #expect(unverified.count == 1)
        #expect(notes.count == 1)
        // Every finding lands in exactly one of the severity filters.
        #expect(Set(problems + unverified + notes) == Set(issues))
        #expect(problems.count + unverified.count + notes.count == issues.count)
    }

    // MARK: Selection

    /// The detail column opens on a finding rather than on "Select a Finding", and
    /// it has to be the row the user sees first. The list draws Problems, then Could
    /// Not Verify, then Worth Knowing; `displayOrdered` sorts by severity the same
    /// way, which is the only reason the first match is the top row.
    @Test("With nothing selected, the top row on screen is chosen")
    func selectsTheTopRow() throws {
        let browser = SetupCheckBrowserState()
        browser.reconcileSelection(issues: Self.mixed)

        let selected = try #require(browser.selectedIssueID)
        let issue = try #require(Self.mixed.first { $0.id == selected })
        #expect(issue.severity == .problem)
        #expect(selected == Self.mixed.first?.id)
    }

    /// A re-audit calls this with the same findings. Snapping back to the first row
    /// each time would pull the detail out from under someone reading another one.
    @Test("A selection that is still listed is kept")
    func keepsAVisibleSelection() throws {
        let browser = SetupCheckBrowserState()
        let note = try #require(Self.mixed.first { $0.severity == .note })
        browser.selectedIssueID = note.id

        browser.reconcileSelection(issues: Self.mixed)

        #expect(browser.selectedIssueID == note.id)
    }

    /// Switching to Problems while a note is selected must not leave the detail
    /// showing a note the list beside it no longer contains.
    @Test("A selection the filter hides moves to the first finding it shows")
    func filteredOutSelectionMoves() throws {
        let browser = SetupCheckBrowserState()
        let note = try #require(Self.mixed.first { $0.severity == .note })
        browser.selectedIssueID = note.id

        browser.filter = .problems
        browser.reconcileSelection(issues: Self.mixed)

        #expect(browser.selectedIssueID == SetupCheckFilter.problems.filter(issues: Self.mixed).first?.id)
    }

    /// Ignoring a finding removes it from the store. The detail must move on rather
    /// than hold an id that points at nothing.
    @Test("An ignored finding does not stay selected")
    func dismissedSelectionMoves() throws {
        let browser = SetupCheckBrowserState()
        let top = try #require(Self.mixed.first)
        browser.selectedIssueID = top.id

        let remaining = Self.mixed.filter { $0.id != top.id }
        browser.reconcileSelection(issues: remaining)

        #expect(browser.selectedIssueID == remaining.first?.id)
        #expect(browser.selectedIssueID != top.id)
    }

    /// A filter whose last finding was fixed or ignored is no longer offered, so it
    /// cannot stay chosen with nothing in the bar selected. It falls back to All,
    /// and the selection follows.
    @Test("A filter left with nothing in it falls back to All")
    func emptiedFilterFallsBackToAll() {
        let browser = SetupCheckBrowserState()
        let onlyProblems = Self.mixed.filter { $0.severity == .problem }
        browser.filter = .notes

        browser.reconcileSelection(issues: onlyProblems)

        #expect(browser.filter == .all)
        #expect(browser.selectedIssueID == onlyProblems.first?.id)
    }

    /// No findings means no selection, so the detail column falls back to its
    /// all-clear or placeholder instead of rendering a stale finding.
    @Test("With no findings, nothing is selected")
    func noFindingsClearsSelection() {
        let browser = SetupCheckBrowserState()
        browser.selectedIssueID = Self.mixed.first?.id

        browser.reconcileSelection(issues: [])

        #expect(browser.selectedIssueID == nil)
    }

    @Test("Only severities with findings are offered as filters")
    func offersOnlyNonEmptyFilters() {
        #expect(SetupCheckFilter.available(for: Self.mixed) == [.all, .problems, .unverified, .notes])
        #expect(SetupCheckFilter.available(for: Self.mixed.filter { $0.severity != .unknown }) == [.all, .problems, .notes])
        #expect(SetupCheckFilter.available(for: []) == [.all])
    }

    // MARK: Summary

    private static func summary(
        coverage: SetupCheckCoverage = .audited(["Sonarr"]),
        audited: Bool = true,
        problems: Int = 0,
        unknowns: Int = 0,
        notes: Int = 0
    ) -> SetupCheckSummary {
        SetupCheckSummary(coverage: coverage, hasCompletedAnAudit: audited, problems: problems, unknowns: unknowns, notes: notes)
    }

    /// The header, the navigation subtitle and the System row all read this, so the
    /// order of these rules is the order the screen claims things in.
    @Test("The summary never calls an unchecked or partial setup clear")
    func summaryStatusOrder() {
        #expect(Self.summary(coverage: .nothingConfigured, problems: 3).status == .nothingConfigured)
        #expect(Self.summary(audited: false).status == .checking)
        #expect(Self.summary(problems: 1, unknowns: 2).status == .problems)
        #expect(Self.summary(unknowns: 1, notes: 4).status == .incomplete)
        #expect(Self.summary(notes: 2).status == .clear)
        #expect(Self.summary().status == .clear)
    }

    @Test("The subtitle counts the most serious thing")
    func summarySubtitle() {
        #expect(Self.summary(problems: 1).subtitle == "1 Problem")
        #expect(Self.summary(problems: 4, notes: 2).subtitle == "4 Problems")
        #expect(Self.summary(unknowns: 2).subtitle == "2 Unverified")
        #expect(Self.summary(notes: 1).subtitle == "1 Note")
        #expect(Self.summary().subtitle == "All Clear")
        #expect(Self.summary(coverage: .nothingConfigured).subtitle == "Nothing to Check")
    }

    /// The all-clear names what was read, so it cannot claim services that are not
    /// configured.
    @Test("An all-clear names only the services it checked")
    func allClearNamesCoverage() {
        let clear = Self.summary(coverage: .audited(["Radarr", "Sonarr"]))
        #expect(clear.message.contains("Radarr and Sonarr"))
        #expect(!clear.message.contains("Prowlarr"))
    }

    // MARK: What an empty result may claim

    /// The bug this type exists for: an empty audit on a fresh install rendered as
    /// "Everything Is Wired Up". Nothing configured is not a pass.
    @Test("With nothing configured there is nothing to claim")
    func nothingConfiguredIsNotAPass() {
        let coverage = SetupCheckCoverage(
            arrServices: [], hasQBittorrent: false, hasSABnzbd: false, hasSeerr: false, hasCleanuparr: false
        )
        #expect(coverage == .nothingConfigured)
        #expect(coverage.auditedSummary == nil)
    }

    @Test("An HD/4K pair is named once, and load order does not reorder the sentence")
    func namesEachServiceOnce() {
        let loadedOneWay = SetupCheckCoverage(
            arrServices: [.radarr, .sonarr, .radarr], hasQBittorrent: true, hasSABnzbd: false, hasSeerr: false, hasCleanuparr: false
        )
        let loadedAnother = SetupCheckCoverage(
            arrServices: [.sonarr, .radarr], hasQBittorrent: true, hasSABnzbd: false, hasSeerr: false, hasCleanuparr: false
        )
        #expect(loadedOneWay == .audited(["Radarr", "Sonarr", "qBittorrent"]))
        #expect(loadedOneWay == loadedAnother)
    }

    @Test("The summary reads as a sentence at every length")
    func summaryJoins() {
        #expect(SetupCheckCoverage.audited(["Sonarr"]).auditedSummary == "Sonarr")
        #expect(SetupCheckCoverage.audited(["Radarr", "Sonarr"]).auditedSummary == "Radarr and Sonarr")
        #expect(SetupCheckCoverage.audited(["Radarr", "Sonarr", "qBittorrent"]).auditedSummary == "Radarr, Sonarr and qBittorrent")
    }

    /// Any one configured service is something the audit read, so none of them may
    /// be mistaken for an empty setup.
    @Test("Every kind of configured service counts as something audited")
    func everyServiceKindCounts() {
        let configurations = [
            SetupCheckCoverage(arrServices: [.prowlarr], hasQBittorrent: false, hasSABnzbd: false, hasSeerr: false, hasCleanuparr: false),
            SetupCheckCoverage(arrServices: [], hasQBittorrent: true, hasSABnzbd: false, hasSeerr: false, hasCleanuparr: false),
            SetupCheckCoverage(arrServices: [], hasQBittorrent: false, hasSABnzbd: true, hasSeerr: false, hasCleanuparr: false),
            SetupCheckCoverage(arrServices: [], hasQBittorrent: false, hasSABnzbd: false, hasSeerr: true, hasCleanuparr: false),
            SetupCheckCoverage(arrServices: [], hasQBittorrent: false, hasSABnzbd: false, hasSeerr: false, hasCleanuparr: true)
        ]
        for coverage in configurations {
            #expect(coverage != .nothingConfigured)
            #expect(coverage.auditedSummary != nil)
        }
    }
}
