import SwiftUI

/// Which server (or servers) an add is going to.
///
/// A single instance is the ordinary case. `.everyCandidate` exists because with a
/// pair configured, "put this on both" is a thing people actually want and is
/// otherwise two trips through the same sheet.
enum ArrAddDestination: Hashable {
    case instance(UUID)
    case everyCandidate

    var instanceID: UUID? {
        if case .instance(let id) = self { return id }
        return nil
    }
}

/// Shared state and orchestration for the Sonarr and Radarr add sheets. Keeping
/// destination resolution, per-server configuration, persistence, and partial
/// failure semantics here prevents the two services from drifting apart.
@MainActor
@Observable
final class ArrAddDestinationState {
    let serviceType: ArrServiceType
    var destination: ArrAddDestination?
    var profileByInstance: [UUID: Int] = [:]
    var rootFolderByInstance: [UUID: String] = [:]
    var failureMessage: String?

    init(serviceType: ArrServiceType) {
        self.serviceType = serviceType
    }

    func resolvedDestination(in candidates: [ArrInstanceRef]) -> ArrAddDestination {
        if let destination { return destination }
        let preferred = ArrAddDestinationMemory.preferredServer(for: serviceType, candidates: candidates)
        return preferred.map(ArrAddDestination.instance) ?? .everyCandidate
    }

    func targets(in candidates: [ArrInstanceRef]) -> [ArrInstanceRef] {
        switch resolvedDestination(in: candidates) {
        case .instance(let id): candidates.filter { $0.id == id }
        case .everyCandidate: candidates
        }
    }

    func seedDefaults(
        for candidates: [ArrInstanceRef],
        profiles: (UUID) -> [ArrQualityProfile],
        folders: (UUID) -> [ArrRootFolder]
    ) {
        for ref in candidates {
            let availableProfiles = profiles(ref.id)
            if profileByInstance[ref.id] == nil
                || !availableProfiles.contains(where: { $0.id == profileByInstance[ref.id] }) {
                let remembered = ArrAddDestinationMemory.lastQualityProfile(on: ref.id)
                profileByInstance[ref.id] = availableProfiles.first(where: { $0.id == remembered })?.id
                    ?? availableProfiles.first?.id
            }

            let availableFolders = folders(ref.id)
            if rootFolderByInstance[ref.id] == nil
                || !availableFolders.contains(where: { $0.path == rootFolderByInstance[ref.id] }) {
                let remembered = ArrAddDestinationMemory.lastRootFolder(on: ref.id)
                rootFolderByInstance[ref.id] = availableFolders.first(where: { $0.path == remembered })?.path
                    ?? availableFolders.first?.path
            }
        }
    }

    func isConfigured(_ targets: [ArrInstanceRef]) -> Bool {
        !targets.isEmpty && targets.allSatisfy {
            profileByInstance[$0.id] != nil && rootFolderByInstance[$0.id] != nil
        }
    }

    /// Runs every requested add and succeeds only when every server succeeds.
    /// Successful destinations are remembered immediately, but a partial failure
    /// remains on screen so the user can retry the servers that did not accept it.
    /// - Parameter failureReason: Read immediately after a failed `operation`, to
    ///   pick up the message the caller's view model caught. It has to be read *then*
    ///   rather than after the loop: the Arr view models keep their last error in
    ///   `ArrLibraryViewModel.error`, which is shared library state that the next
    ///   library reload clears - so a message read a moment later is frequently gone,
    ///   and the sheet says only that the add failed while the server's own words are
    ///   thrown away.
    func execute(
        targets: [ArrInstanceRef],
        itemName: String? = nil,
        failureReason: () -> String? = { nil },
        operation: (ArrInstanceRef, Int, String) async -> Bool
    ) async -> Bool {
        var failed: [ArrInstanceRef] = []
        var reasons: [String] = []

        for target in targets {
            guard let profileID = profileByInstance[target.id],
                  let folderPath = rootFolderByInstance[target.id] else {
                failed.append(target)
                continue
            }
            if await operation(target, profileID, folderPath) {
                ArrAddDestinationMemory.rememberQualityProfile(profileID, on: target.id)
                ArrAddDestinationMemory.rememberRootFolder(folderPath, on: target.id)
            } else {
                failed.append(target)
                if let reason = failureReason()?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !reason.isEmpty, !reasons.contains(reason) {
                    reasons.append(reason)
                }
            }
        }

        guard failed.isEmpty else {
            let cause = reasons.isEmpty ? "" : " \(reasons.joined(separator: " "))"
            failureMessage = "Could not add to \(failed.map(\.qualifiedLabel).joined(separator: ", ")).\(cause) You can retry without repeating successful destinations."
            destination = failed.count == 1 ? .instance(failed[0].id) : .everyCandidate
            if itemName != nil, let failureMessage {
                ArrOperationFeedback.showFailure(title: "Add Failed", message: failureMessage)
            }
            return false
        }

        failureMessage = nil
        ArrAddDestinationMemory.rememberServer(
            resolvedDestination(in: targets).instanceID,
            for: serviceType
        )
        if let itemName {
            let destinationNames = targets.map(\.qualifiedLabel).joined(separator: ", ")
            ArrOperationFeedback.showSuccess(
                title: "Added",
                message: "\(itemName) was added to \(destinationNames)."
            )
        }
        return true
    }
}

/// Remembers the server, quality profile and root folder an add last used, so the
/// sheet opens on the answer that was right last time.
///
/// Two levels, because they have different lifetimes. The *server* is a per-service
/// habit - someone who files everything on the second box wants that preselected
/// every time. The *profile and root folder* are per-server facts: a profile id
/// only means something on the server it came from, so remembering one globally
/// would preselect an id the other server has never heard of and fail at the API
/// rather than in the UI.
///
/// Deliberately a preference and not a setting: nothing here is worth a row in
/// Settings, and a wrong guess costs one tap to correct.
@MainActor
enum ArrAddDestinationMemory {
    /// Injectable so tests do not write into the app's real defaults, and so one
    /// test cannot leak a preference into the next.
    static var store: UserDefaults = .standard

    private static func serverKey(_ serviceType: ArrServiceType) -> String {
        "arr.add.lastServer.\(serviceType.rawValue)"
    }
    private static func profileKey(_ instanceID: UUID) -> String {
        "arr.add.lastQualityProfile.\(instanceID.uuidString)"
    }
    private static func rootFolderKey(_ instanceID: UUID) -> String {
        "arr.add.lastRootFolder.\(instanceID.uuidString)"
    }

    static func lastServer(for serviceType: ArrServiceType) -> UUID? {
        store.string(forKey: serverKey(serviceType)).flatMap(UUID.init(uuidString:))
    }

    static func rememberServer(_ instanceID: UUID?, for serviceType: ArrServiceType) {
        guard let instanceID else { return }
        store.set(instanceID.uuidString, forKey: serverKey(serviceType))
    }

    static func lastQualityProfile(on instanceID: UUID) -> Int? {
        // `object(forKey:)` rather than `integer(forKey:)`: the latter reports 0 for
        // "never set", and 0 is a plausible-looking profile id.
        store.object(forKey: profileKey(instanceID)) as? Int
    }

    static func rememberQualityProfile(_ id: Int?, on instanceID: UUID?) {
        guard let id, let instanceID else { return }
        store.set(id, forKey: profileKey(instanceID))
    }

    static func lastRootFolder(on instanceID: UUID) -> String? {
        store.string(forKey: rootFolderKey(instanceID))
    }

    static func rememberRootFolder(_ path: String?, on instanceID: UUID?) {
        guard let path, let instanceID else { return }
        store.set(path, forKey: rootFolderKey(instanceID))
    }

    /// The server an add should open on: the remembered one when it is still a
    /// candidate, otherwise the first candidate. Never returns a server that is not
    /// in `candidates` - a remembered id survives the server being removed, or the
    /// title being added there since.
    static func preferredServer(
        for serviceType: ArrServiceType,
        candidates: [ArrInstanceRef]
    ) -> UUID? {
        if let remembered = lastServer(for: serviceType),
           candidates.contains(where: { $0.id == remembered }) {
            return remembered
        }
        return candidates.first?.id
    }
}

/// Picks the destination for an add when there is more than one candidate server.
///
/// Renders nothing for a single candidate: there is nothing to disambiguate, and a
/// picker with one row is a control that can only tell you what you already know.
struct ArrAddDestinationPicker: View {
    let candidates: [ArrInstanceRef]
    @Binding var selection: ArrAddDestination
    /// Whether to offer "Both servers". Suppressed when the title is already on one
    /// of the pair, since "both" would then mean "one".
    var allowsEveryCandidate: Bool = true

    @Environment(ArrServiceManager.self) private var serviceManager

    var body: some View {
        if candidates.count > 1 {
            Picker("Server", selection: $selection) {
                ForEach(candidates) { ref in
                    Text(serviceManager.scopeLabel(for: ref))
                        .tag(ArrAddDestination.instance(ref.id))
                }
                if allowsEveryCandidate {
                    Text("Both Servers").tag(ArrAddDestination.everyCandidate)
                }
            }
        }
    }
}

nonisolated extension ArrLibraryEntry {
    /// The configured servers that do not yet hold this title.
    ///
    /// Written as "which servers are missing this" rather than "is the 4K server
    /// missing it" on purpose. The second phrasing bakes in a hierarchy - a base
    /// server and an upgrade - and there isn't one: a title can land on either
    /// server first, Seerr can request to one independently, and the second server
    /// is not necessarily the 4K one in how its owner actually uses it. Asking the
    /// symmetric question gets every direction for free.
    func instancesMissingThis(from refs: [ArrInstanceRef]) -> [ArrInstanceRef] {
        let holding = Set(instanceIDs)
        return refs.filter { !holding.contains($0.id) }
    }
}
