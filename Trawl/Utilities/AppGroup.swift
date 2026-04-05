import Foundation

enum AppGroup {
    nonisolated static let identifier = "group.com.poole.james.Trawl"
    nonisolated static let keychainGroup = "com.poole.james.Trawl.shared"

    static var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
