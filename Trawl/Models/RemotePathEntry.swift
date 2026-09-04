import Foundation

nonisolated struct RemotePathEntry: Identifiable, Hashable, Sendable {
    let name: String
    let path: String
    let kind: RemotePathEntryKind
    let isDirectory: Bool

    var id: String { "\(kind.rawValue)|\(path)|\(name)" }
}

