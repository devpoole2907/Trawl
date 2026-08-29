import SwiftUI

/// Picks which server an admin screen is showing.
///
/// The per-server settings - download clients, naming formats, quality
/// definitions, scheduled tasks, backups - are configured on one server and an
/// HD/4K pair rarely agrees on any of them. These screens used to offer a
/// Sonarr/Radarr choice, which silently meant "whichever of the two happened to
/// be active"; they now offer the servers themselves.
///
/// Labels stay at the service name while a service has one server and grow the
/// tier only when there is a second, so the extra word appears exactly when it
/// starts meaning something.
struct ArrInstanceScopeBar: View {
    let instances: [ArrInstanceRef]
    @Binding var selection: UUID?
    var title: String = "Server"

    @Environment(ArrServiceManager.self) private var serviceManager

    var body: some View {
        if instances.count > 1 {
            TrawlSegmentBar(
                title,
                selection: Binding(
                    get: { selection ?? instances.first?.id },
                    set: { newValue in withAnimation { selection = newValue } }
                ),
                items: instances.map { TrawlSegmentBarItem(label(for: $0), value: Optional($0.id)) },
                alignment: .leading
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    private func label(for ref: ArrInstanceRef) -> String {
        ArrInstanceScopeBar.label(for: ref, in: serviceManager)
    }

    /// "Radarr" with one Radarr configured, "Radarr 4K" with two.
    static func label(for ref: ArrInstanceRef, in serviceManager: ArrServiceManager) -> String {
        guard serviceManager.showsInstanceProvenance(for: ref.serviceType) else {
            return ref.serviceType.displayName
        }
        // A tierless service has no "Default"/"4K" to tell its servers apart -
        // every one of them reports the default tier, so tier-based labels would
        // render two identical segments. The name the user gave the server is the
        // only thing that distinguishes them.
        guard ArrSetupViewModel.usesQualityTiers(ref.serviceType) else {
            return ref.displayName
        }
        return "\(ref.serviceType.displayName) \(ref.shortLabel)"
    }
}

extension ArrServiceManager {
    /// The label an admin screen should use for one server, in a section header,
    /// a picker row or a confirmation.
    func scopeLabel(for ref: ArrInstanceRef) -> String {
        ArrInstanceScopeBar.label(for: ref, in: self)
    }

    /// The selection an admin screen should fall back to when its stored one is
    /// gone - the first connected server, preferring one that is actually up.
    func defaultScopeInstanceID(preferring current: UUID?) -> UUID? {
        let available = visibleArrInstances.map(\.ref)
        if let current, available.contains(where: { $0.id == current }) { return current }
        return available.first?.id
    }
}
