import SwiftUI

/// The Disk Space list's selection and shared state, owned above the
/// split view so the two native columns share it.
@MainActor
@Observable
final class ArrDiskSpaceBrowserState {
    var snapshots: [ArrDiskSpaceSnapshot] = []
    var selectedDiskID: String?
    var isLoading = false

    func loadDiskSpace(serviceManager: ArrServiceManager) async {
        isLoading = true
        defer { isLoading = false }
        var all: [ArrDiskSpaceSnapshot] = []
        for (ref, client) in serviceManager.visibleArrInstances {
            all += await loadDiskSpace(from: client, instance: ref)
        }
        snapshots = all
        reconcileSelection()
    }

    private func loadDiskSpace(
        from client: (any SharedArrClient)?,
        instance: ArrInstanceRef
    ) async -> [ArrDiskSpaceSnapshot] {
        guard let client else { return [] }

        do {
            return try await client.getDiskSpace().map {
                ArrDiskSpaceSnapshot(
                    serviceType: instance.serviceType,
                    path: $0.path ?? "Unknown",
                    label: $0.label,
                    freeSpace: $0.freeSpace,
                    totalSpace: $0.totalSpace,
                    instance: instance
                )
            }
        } catch {
            return []
        }
    }

    func reconcileSelection() {
        if let selected = selectedDiskID, !snapshots.contains(where: { $0.id == selected }) {
            selectedDiskID = snapshots.first?.id
        } else if selectedDiskID == nil {
            selectedDiskID = snapshots.first?.id
        }
    }
}
