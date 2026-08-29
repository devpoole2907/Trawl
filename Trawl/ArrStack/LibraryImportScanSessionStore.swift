//
//  LibraryImportScanSessionStore.swift
//  Trawl
//
//  Keeps a folder's scan alive for the app session instead of for one push of
//  the scan view.
//

import Foundation

/// One `LibraryImportScanViewModel` per scanned folder, retained for the app session.
///
/// `LibraryImportScanView` held its view model in `@State`, and SwiftUI destroys that
/// when the view is popped. Everything the screen had earned went with it - the grouped
/// scan, manual identifications, and every Auto Match result - so returning to a folder
/// re-scanned it from scratch and re-ran auto match over files it had already matched.
/// A scan describes the folder, not one visit to it, so it lives here until the user
/// explicitly rescans (pull to refresh), re-runs Auto Match, or relaunches the app.
@MainActor
final class LibraryImportScanSessionStore {
    static let shared = LibraryImportScanSessionStore()

    /// Everything that decides *which* scan this is. `instanceID` is part of it because
    /// an HD/4K pair can expose the same path on two servers with different libraries,
    /// and `kind` is because Library Import and Manual Import scan the same folder with
    /// different server-side filtering.
    struct Key: Hashable {
        let path: String
        let service: ArrServiceType
        let instanceID: UUID?
        let libraryItemID: Int?
        let kind: ArrImportKind
    }

    /// A retained scan holds its decoded file list and a library snapshot, so keeping
    /// them is not free. Holding the handful of folders a user moves between covers
    /// the navigate-away case without letting a long session accumulate every folder
    /// ever opened.
    private let limit: Int
    private var models: [Key: LibraryImportScanViewModel] = [:]
    /// Keys in use order, least-recently-used first.
    private var usageOrder: [Key] = []

    init(limit: Int = 6) {
        self.limit = max(1, limit)
    }

    /// The view model for this folder, creating it on first visit and returning the
    /// same instance - with its scan and matches intact - on every visit after that.
    func viewModel(
        path: String,
        service: ArrServiceType,
        serviceManager: ArrServiceManager,
        instanceID: UUID? = nil,
        libraryItemID: Int? = nil,
        kind: ArrImportKind = .library
    ) -> LibraryImportScanViewModel {
        let key = Key(
            path: path,
            service: service,
            instanceID: instanceID,
            libraryItemID: libraryItemID,
            kind: kind
        )

        if let existing = models[key] {
            touch(key)
            return existing
        }

        let model = LibraryImportScanViewModel(
            path: path,
            service: service,
            serviceManager: serviceManager,
            instanceID: instanceID,
            libraryItemID: libraryItemID,
            kind: kind
        )
        models[key] = model
        touch(key)
        evictOverflow()
        return model
    }

    /// How many scans are currently retained.
    var retainedScanCount: Int { models.count }

    /// Drops every retained scan.
    ///
    /// Nothing in the app calls this yet, deliberately: the obvious trigger would be
    /// `ArrServiceManager.initialize(from:)`, which reruns on any profile change and
    /// would throw away scans for servers the change never touched - reintroducing the
    /// bug this store exists to fix. A scan for a deleted server is unreachable from
    /// the UI and ages out through `limit`, so there is nothing to clean up urgently.
    /// This stays as the explicit reset seam for tests and for a future, narrower
    /// invalidation.
    func removeAll() {
        for model in models.values {
            model.stopAutoIdentify()
        }
        models.removeAll()
        usageOrder.removeAll()
    }

    private func touch(_ key: Key) {
        usageOrder.removeAll { $0 == key }
        usageOrder.append(key)
    }

    private func evictOverflow() {
        while usageOrder.count > limit {
            let oldest = usageOrder.removeFirst()
            // An evicted scan may still have an auto-match loop running against it.
            models[oldest]?.stopAutoIdentify()
            models.removeValue(forKey: oldest)
        }
    }
}
