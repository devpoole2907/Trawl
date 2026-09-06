import SwiftUI

/// The server holding this mapping. Remote path mappings translate a download
/// client's paths into the *arr's own, and each server has its own view of the
/// filesystem - a pair sharing a client still needs a mapping each.
struct RemotePathMappingEntry: Identifiable, Sendable, Hashable {
    let serviceType: ArrServiceType
    let mapping: ArrRemotePathMapping
    var instance: ArrInstanceRef?

    // Both instances number their mappings from the same sequence.
    var id: String { "\(instance?.id.uuidString ?? serviceType.rawValue)-\(mapping.id)" }
}

/// The Remote Path Mappings list's selection and shared state, owned above the
/// split view so the two native columns share it.
@MainActor
@Observable
final class ArrRemotePathMappingBrowserState {
    var selectedMappingID: String?
    var mappings: [RemotePathMappingEntry] = []
    var isLoading = false
    var loadError: String?

    func sortMappings() {
        mappings.sort {
            if $0.serviceType != $1.serviceType {
                return $0.serviceType.displayName < $1.serviceType.displayName
            }
            // HD before 4K within a service, so the pair reads in a stable order.
            if $0.instance?.ordinal != $1.instance?.ordinal {
                return ($0.instance?.ordinal ?? 0) < ($1.instance?.ordinal ?? 0)
            }
            return $0.mapping.host.localizedCaseInsensitiveCompare($1.mapping.host) == .orderedAscending
        }
    }
}
