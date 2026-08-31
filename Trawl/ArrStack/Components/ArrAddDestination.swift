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
