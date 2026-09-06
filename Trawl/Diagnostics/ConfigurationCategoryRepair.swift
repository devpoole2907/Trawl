//
//  ConfigurationCategoryRepair.swift
//  Trawl
//
//  Applies the wizard's "give each server its own download category" repair.
//

import Foundation
import OSLog

/// Runs the ordered change the audit planned.
///
/// Split from the view for the same reason the audit is split from its store: the
/// ordering is the part that has to be right, and it should be provable without a
/// window. The order is not a style choice - Arr validates a download client's
/// category against the client itself when the client is saved, so a category
/// SABnzbd has never heard of comes back as HTTP 400. The category has to exist on
/// SABnzbd first, which is the step a person doing this by hand does second.
///
/// qBittorrent is deliberately not given the same pre-step. It creates a category on
/// first use and Arr does not validate against it, so there is nothing to do ahead of
/// the save and inventing a step would only add a way to fail.
@MainActor
struct ConfigurationCategoryRepair {

    /// What happened to one server's half of the repair.
    enum Outcome: Hashable, Sendable {
        case pending
        case running
        /// Applied. The message names what was actually done, including whether a
        /// SABnzbd category had to be created, because "done" alone leaves the user
        /// unsure whether to go and check SABnzbd themselves.
        case succeeded(String)
        case failed(String)

        var isTerminal: Bool {
            switch self {
            case .pending, .running: false
            case .succeeded, .failed: true
            }
        }
    }

    /// One server's change, with whatever the user edited applied to it.
    struct Plan: Identifiable, Hashable, Sendable {
        let change: ConfigurationGuidedRepair.DownloadCategoryChange
        /// What will actually be written. Starts as the suggestion and follows the
        /// text field.
        var category: String

        var id: UUID { change.id }

        init(_ change: ConfigurationGuidedRepair.DownloadCategoryChange) {
            self.change = change
            self.category = change.suggestedCategory
        }

        /// Lowercased and stripped, because that is what ends up on disk and what
        /// every comparison in the audit is made against. A category typed as
        /// "Movies 4K" and one read back as "movies 4k" are the same category, and a
        /// repair that writes the former re-reports itself on the next audit.
        var normalizedCategory: String {
            category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        var isValid: Bool {
            let value = normalizedCategory
            guard !value.isEmpty else { return false }
            // SABnzbd's own catch-all, and a path separator, are the two things that
            // are accepted by the text field and mean something else entirely once
            // written.
            return value != "*" && !value.contains("/") && !value.contains("\\")
        }
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Trawl",
        category: "ConfigurationCategoryRepair"
    )

    let serviceManager: ArrServiceManager
    /// Optional because the repair still runs without it: only a shared SABnzbd
    /// needs a category created ahead of the save, and a qBittorrent setup never
    /// touches this.
    let sabnzbdServiceManager: SABnzbdServiceManager?
    /// Endpoints of the SABnzbd connections Trawl holds, so the repair can tell a
    /// shared SABnzbd from a shared qBittorrent without asking the Arr what it is.
    let sabnzbdEndpoints: Set<String>
    /// The endpoint of the SABnzbd Trawl is currently connected to, when it has one.
    /// SABnzbd's manager talks to a single active profile, so a shared server that
    /// is configured but not the active one cannot be written to.
    let activeSabnzbdEndpoint: String?

    /// Applies one server's change: create the category if it needs creating, then
    /// repoint the download client at it.
    func apply(_ plan: Plan) async -> Outcome {
        let category = plan.normalizedCategory
        guard plan.isValid else {
            return .failed("\"\(plan.category)\" is not a category name SABnzbd or qBittorrent will accept.")
        }

        var createdCategory = false
        if sabnzbdEndpoints.contains(plan.change.endpoint) {
            guard activeSabnzbdEndpoint == plan.change.endpoint, let sabnzbdServiceManager else {
                return .failed("Trawl is not connected to the SABnzbd at \(plan.change.endpoint), so it cannot create the \"\(category)\" category there. \(plan.change.serverName) was left unchanged.")
            }
            do {
                createdCategory = try await createCategoryIfNeeded(category, using: sabnzbdServiceManager)
            } catch {
                return .failed("Could not create the \"\(category)\" category in SABnzbd: \(error.localizedDescription). \(plan.change.serverName) was left unchanged.")
            }
        }

        do {
            try await repointDownloadClient(plan, to: category)
        } catch {
            // The category is left in place on purpose. It is inert on its own, and
            // deleting it would take out one the user already had if the name
            // collided with something this repair did not create.
            return .failed("Could not update \(plan.change.serverName): \(error.localizedDescription)")
        }

        Self.logger.info("Repointed download client \(plan.change.downloadClientID) on \(plan.change.serverName, privacy: .public) to category \(category, privacy: .public)")
        return .succeeded(
            createdCategory
                ? "Created the \"\(category)\" category in SABnzbd and pointed \(plan.change.serverName) at it."
                : "\(plan.change.serverName) now uses the \"\(category)\" category."
        )
    }

    /// True when a category was created, false when SABnzbd already had one by that
    /// name. An existing category is left exactly as it is: it may already have a
    /// folder, a script and a priority the user set, and overwriting those to assert
    /// a default would be a change nobody asked for.
    private func createCategoryIfNeeded(
        _ category: String,
        using manager: SABnzbdServiceManager
    ) async throws -> Bool {
        await manager.refreshCategoryConfigs()
        if manager.categoryConfigs.contains(where: { $0.name.lowercased() == category }) { return false }
        // A folder of its own is the point of the exercise. Without one the category
        // exists but still writes into SABnzbd's completed-downloads root, which is
        // the shared folder this repair is pulling apart.
        try await manager.saveCategory(
            SABnzbdCategory(name: category, directory: category),
            originalName: nil
        )
        return true
    }

    /// Re-reads the client before writing it.
    ///
    /// The audit's snapshot is minutes old by the time anyone presses a button, and a
    /// download client is a whole object on the wire: writing back a stale copy would
    /// revert every other field to what it was when the audit ran.
    private func repointDownloadClient(_ plan: Plan, to category: String) async throws {
        let ref = serviceManager.instanceRef(plan.change.serviceType, id: plan.change.instanceID)
            ?? ArrInstanceRef(
                id: plan.change.instanceID,
                serviceType: plan.change.serviceType,
                displayName: plan.change.serverName,
                tier: .hd
            )
        guard let client = serviceManager.sharedClient(for: ref) else {
            throw ConfigurationCategoryRepairError.notConnected(plan.change.serverName)
        }

        let existing = try await client.getDownloadClients()
        guard let target = existing.first(where: { $0.id == plan.change.downloadClientID }) else {
            throw ConfigurationCategoryRepairError.clientGone(plan.change.downloadClientName)
        }
        guard let fieldName = target.categoryFieldName else {
            throw ConfigurationCategoryRepairError.noCategoryField(plan.change.downloadClientName)
        }

        _ = try await client.updateDownloadClient(
            target.updatingField(named: fieldName, with: .string(category))
        )
    }
}

enum ConfigurationCategoryRepairError: LocalizedError {
    case notConnected(String)
    case clientGone(String)
    case noCategoryField(String)

    var errorDescription: String? {
        switch self {
        case .notConnected(let name):
            "Trawl is not connected to \(name)."
        case .clientGone(let name):
            "\"\(name)\" is no longer on that server. Run the setup check again."
        case .noCategoryField(let name):
            "\"\(name)\" does not have a category setting to change."
        }
    }
}
