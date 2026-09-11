//
//  SetupCheckBrowserState.swift
//  Trawl
//
//  Selection and filtering state for the Setup Check split view.
//

import SwiftUI
import Foundation
import Observation

/// The Setup Check's selection and filter state, owned above the split view
/// so both native columns (list and detail) share it.
@MainActor
@Observable
final class SetupCheckBrowserState {
    var selectedIssueID: String?
    var filter: SetupCheckFilter = .all

    func reconcileSelection(issues: [ConfigurationIssue]) {
        let matching = filter.filter(issues: issues)
        if let selected = selectedIssueID, matching.contains(where: { $0.id == selected }) {
            return
        }
        // Auto-select the first issue (prioritizing problems, then unverified, then notes)
        selectedIssueID = matching.first?.id
    }
}

enum SetupCheckFilter: String, CaseIterable, Hashable, Identifiable {
    case all = "All"
    case problems = "Problems"
    case unverified = "Unverified"
    case notes = "Notes"

    var id: String { rawValue }

    func filter(issues: [ConfigurationIssue]) -> [ConfigurationIssue] {
        switch self {
        case .all:
            return issues
        case .problems:
            return issues.filter { $0.severity == .problem }
        case .unverified:
            return issues.filter { $0.severity == .unknown }
        case .notes:
            return issues.filter { $0.severity == .note }
        }
    }
}

/// What an empty Setup Check can honestly say.
///
/// An audit that finds nothing has only checked what is configured. With nothing
/// configured it has checked nothing at all - and the screen used to announce
/// "Everything Is Wired Up", with ticks for download clients, root folders, indexer
/// sync and categories, regardless. A fresh install claimed indexer sync was active
/// for an indexer manager that did not exist. So an empty result is one of two
/// different things, and the screen has to be told which.
enum SetupCheckCoverage: Equatable {
    /// Nothing is configured, so nothing was audited. Not a pass.
    case nothingConfigured
    /// These services were read by the audit and nothing was found wrong with them.
    case audited([String])

    init(
        arrServices: [ArrServiceType],
        hasQBittorrent: Bool,
        hasSABnzbd: Bool,
        hasSeerr: Bool,
        hasCleanuparr: Bool
    ) {
        // Each Arr service once, however many instances: an HD/4K pair is still
        // "Radarr", and naming it twice reads as a count. Sorted, so the sentence
        // does not reshuffle with the order profiles happen to load in.
        var names = Array(Set(arrServices.map(\.displayName))).sorted()
        if hasQBittorrent { names.append("qBittorrent") }
        if hasSABnzbd { names.append("SABnzbd") }
        if hasSeerr { names.append("Seerr") }
        if hasCleanuparr { names.append("Cleanuparr") }
        self = names.isEmpty ? .nothingConfigured : .audited(names)
    }

    /// "Radarr, Sonarr and qBittorrent" - the services an all-clear is about, or
    /// `nil` when there are none and an all-clear must not be shown at all.
    var auditedSummary: String? {
        guard case .audited(let names) = self, let last = names.last else { return nil }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}
