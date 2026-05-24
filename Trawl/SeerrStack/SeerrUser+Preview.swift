#if DEBUG
import Foundation

extension SeerrUser {
    static let preview = SeerrUser.makePreview()
    static let previewAdmin = SeerrUser.makePreview(id: 1, displayName: "Admin", permissions: SeerrPermission.admin.rawValue)
    static let previewRequester = SeerrUser.makePreview(
        id: 5,
        displayName: "Request Manager",
        jellyfinUsername: "request_manager",
        email: "requests@example.com",
        permissions: SeerrPermission.request.rawValue
            | SeerrPermission.manageRequests.rawValue
            | SeerrPermission.viewIssues.rawValue
            | SeerrPermission.createIssues.rawValue
    )
    static let previewLongName = SeerrUser.makePreview(
        id: 6,
        displayName: "A Very Long Seerr Display Name That Wraps In Tight Permission Rows",
        email: "long.name@example.com"
    )
    static let previewList: [SeerrUser] = [
        previewAdmin,
        preview,
        .makePreview(id: 3, displayName: "Alice", jellyfinUsername: "alice_jf"),
        .makePreview(id: 4, displayName: "Bob"),
        previewRequester,
    ]

    fileprivate static func makePreview(
        id: Int = 2,
        displayName: String = "Preview User",
        jellyfinUsername: String? = nil,
        email: String? = nil,
        permissions: Int = 0
    ) -> SeerrUser {
        let json: [String: Any] = [
            "id": id,
            "displayName": displayName,
            "jellyfinUsername": jellyfinUsername ?? NSNull(),
            "email": email ?? NSNull(),
            "userType": 1,
            "permissions": permissions,
            "requestCount": 5,
            "createdAt": "2024-01-01T00:00:00.000Z",
            "updatedAt": "2024-01-15T12:00:00.000Z"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json, options: [])
        return try! JSONDecoder().decode(SeerrUser.self, from: data)
    }
}
#endif
