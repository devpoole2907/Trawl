import Foundation
import SwiftUI

@MainActor
class ArrLibraryViewModel<Item: Identifiable, Client: SharedArrClient> where Item.ID == Int {
    var items: [Item] = []
    var isLoading = false
    var error: String?

    var client: Client?
    var serviceManager: ArrServiceManager

    init(serviceManager: ArrServiceManager, client: Client?) {
        self.serviceManager = serviceManager
        self.client = client
    }

    @discardableResult
    func performLoad<T>(_ work: (Client) async throws -> T) async -> T? {
        guard let client else { return nil }
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            return try await work(client)
        } catch {
            captureAndNotify(error, title: "Load Failed")
            return nil
        }
    }

    func captureAndNotify(_ error: Error, title: String) {
        self.error = error.localizedDescription
        InAppNotificationCenter.shared.showError(
            title: title,
            message: error.localizedDescription
        )
    }

    func notifySuccess(title: String, message: String) {
        error = nil
        InAppNotificationCenter.shared.showSuccess(title: title, message: message)
    }

    func setLibraryItems(_ items: [Item]) {
        self.items = items
    }

    func afterMutation(reload: () async -> Void, refreshCalendar: Bool = true) async {
        await reload()
        if refreshCalendar {
            await serviceManager.calendarViewModel.refresh()
        }
    }
}

struct PaginatedLoader<Item> {
    private(set) var page = 1
    let pageSize: Int
    private(set) var totalRecords = 0
    private(set) var items: [Item] = []

    init(pageSize: Int = 20) {
        self.pageSize = pageSize
    }

    var canLoadMore: Bool {
        items.count < totalRecords
    }

    mutating func reset() {
        page = 1
        totalRecords = 0
        items = []
    }

    mutating func replace(with records: [Item], page: Int = 1, totalRecords: Int? = nil) {
        self.items = records
        self.page = page
        self.totalRecords = totalRecords ?? records.count
    }

    mutating func append(_ records: [Item], page: Int, totalRecords: Int? = nil) {
        items.append(contentsOf: records)
        self.page = page
        self.totalRecords = totalRecords ?? items.count
    }
}

struct StreamingSearchTracker<Result> {
    private(set) var token: UUID?

    mutating func begin() -> UUID {
        let token = UUID()
        self.token = token
        return token
    }

    mutating func cancel() {
        token = nil
    }

    func isCurrent(_ token: UUID) -> Bool {
        self.token == token
    }

    func stream(_ items: [Result], token: UUID, onAppend: @MainActor @Sendable (Result) -> Void) async {
        for item in items {
            guard !Task.isCancelled && isCurrent(token) else { break }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                onAppend(item)
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
    }
}
