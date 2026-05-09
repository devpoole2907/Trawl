import Foundation

struct SeerrUser: Codable, Identifiable, Sendable {
    let id: Int
    let displayNameValue: String?
    let jellyfinUsername: String?
    let discordUsername: String?
    let email: String?
    let username: String?
    let plexUsername: String?
    let userType: Int?
    let permissions: Int?
    let avatar: String?
    let createdAt: String?
    let updatedAt: String?
    let requestCount: Int?

    var displayName: String {
        displayNameValue ??
        jellyfinUsername ??
        username ??
        plexUsername ??
        discordUsername ??
        fallbackNameFromEmail ??
        "User"
    }

    var avatarURL: URL? {
        guard let avatar, !avatar.isEmpty else { return nil }
        return URL(string: avatar)
    }

    // Permission bit flags
    var isAdmin: Bool { hasPermission(SeerrPermission.admin.rawValue) }
    var canManageUsers: Bool { hasPermission(SeerrPermission.manageUsers.rawValue) }
    var canManageRequests: Bool { hasPermission(SeerrPermission.manageRequests.rawValue) }
    var canRequest: Bool { hasPermission(SeerrPermission.request.rawValue) }
    var canManageIssues: Bool { hasPermission(SeerrPermission.manageIssues.rawValue) }
    var canViewIssues: Bool { hasPermission(SeerrPermission.viewIssues.rawValue) }
    var canCreateIssues: Bool { hasPermission(SeerrPermission.createIssues.rawValue) }
    var canAutoApprove: Bool { hasPermission(SeerrPermission.autoApprove.rawValue) }
    var permissionLevelLabel: String { SeerrPermission.permissionLevelLabel(for: permissions) }

    private func hasPermission(_ flag: Int) -> Bool {
        guard let permissions else { return false }
        // Admin has all permissions
        if permissions & SeerrPermission.admin.rawValue != 0 { return true }
        return permissions & flag != 0
    }

    private var fallbackNameFromEmail: String? {
        guard let email, let localPart = email.split(separator: "@").first, !localPart.isEmpty else {
            return nil
        }
        return localPart
            .split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
            .map { chunk in
                let value = String(chunk)
                return value.prefix(1).uppercased() + value.dropFirst()
            }
            .joined(separator: " ")
    }

    enum CodingKeys: String, CodingKey {
        case id
        case displayNameValue = "displayName"
        case jellyfinUsername
        case discordUsername
        case email
        case username
        case plexUsername
        case userType
        case permissions
        case avatar
        case createdAt
        case updatedAt
        case requestCount
    }
}

struct SeerrUserQuota: Codable, Sendable {
    let movie: SeerrQuotaDetail?
    let tv: SeerrQuotaDetail?
}

struct SeerrQuotaDetail: Codable, Sendable {
    let days: Int?
    let limit: Int?
    let used: Int?
    let remaining: Int?
    let restricted: Bool?
}

struct SeerrPublicSettings: Codable, Sendable {
    let initialized: Bool?
    let applicationTitle: String?
    let applicationUrl: String?
    let hideAvailable: Bool?
    let localLogin: Bool?
    let mediaServerType: Int?      // 1 = Plex, 2 = Jellyfin, 3 = Emby
    let partialRequestsEnabled: Bool?

    var isJellyfin: Bool { mediaServerType == 2 }
    var isPlex: Bool { mediaServerType == 1 }
    var isEmby: Bool { mediaServerType == 3 }
}
