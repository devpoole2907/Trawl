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
