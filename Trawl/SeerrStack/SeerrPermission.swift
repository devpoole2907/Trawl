import Foundation

enum SeerrPermission: Int, CaseIterable, Identifiable, Sendable {
    case admin = 2
    case manageUsers = 8
    case manageRequests = 16
    case request = 32
    case vote = 64
    case autoApprove = 128
    case autoApproveMovie = 256
    case autoApproveTV = 512
    case request4K = 1024
    case request4KMovie = 2048
    case request4KTV = 4096
    case requestAdvanced = 8192
    case requestView = 16384
    case autoApprove4K = 32768
    case autoApprove4KMovie = 65536
    case autoApprove4KTV = 131072
    case requestMovie = 262144
    case requestTV = 524288
    case manageIssues = 1_048_576
    case viewIssues = 2_097_152
    case createIssues = 4_194_304
    case autoRequest = 8_388_608
    case autoRequestMovie = 16_777_216
    case autoRequestTV = 33_554_432
    case recentView = 67_108_864
    case watchlistView = 134_217_728

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .admin: "Admin"
        case .manageUsers: "Manage Users"
        case .manageRequests: "Manage Requests"
        case .request: "Request"
        case .vote: "Vote"
        case .autoApprove: "Auto Approve"
        case .autoApproveMovie: "Auto Approve Movies"
        case .autoApproveTV: "Auto Approve TV"
        case .request4K: "Request 4K"
        case .request4KMovie: "Request 4K Movies"
        case .request4KTV: "Request 4K TV"
        case .requestAdvanced: "Advanced Requests"
        case .requestView: "View Requests"
        case .autoApprove4K: "Auto Approve 4K"
        case .autoApprove4KMovie: "Auto Approve 4K Movies"
        case .autoApprove4KTV: "Auto Approve 4K TV"
        case .requestMovie: "Request Movies"
        case .requestTV: "Request TV"
        case .manageIssues: "Manage Issues"
        case .viewIssues: "View Issues"
        case .createIssues: "Create Issues"
        case .autoRequest: "Auto Request"
        case .autoRequestMovie: "Auto Request Movies"
        case .autoRequestTV: "Auto Request TV"
        case .recentView: "Recent View"
        case .watchlistView: "Watchlist View"
        }
    }

    var symbolName: String {
        switch self {
        case .admin: "lock.shield"
        case .manageUsers: "person.2"
        case .manageRequests: "checkmark.circle"
        case .request, .requestMovie, .requestTV, .request4K, .request4KMovie, .request4KTV, .requestAdvanced:
            "plus.circle"
        case .vote: "hand.thumbsup"
        case .autoApprove, .autoApproveMovie, .autoApproveTV, .autoApprove4K, .autoApprove4KMovie, .autoApprove4KTV:
            "bolt.badge.checkmark"
        case .requestView: "list.bullet.clipboard"
        case .manageIssues, .viewIssues, .createIssues: "exclamationmark.bubble"
        case .autoRequest, .autoRequestMovie, .autoRequestTV: "wand.and.stars"
        case .recentView: "clock.arrow.circlepath"
        case .watchlistView: "text.badge.plus"
        }
    }

    var category: SeerrPermissionCategory {
        switch self {
        case .admin, .manageUsers, .manageRequests, .manageIssues:
            .administration
        case .viewIssues, .createIssues, .requestView, .recentView, .watchlistView:
            .visibility
        case .request, .requestMovie, .requestTV, .request4K, .request4KMovie, .request4KTV, .requestAdvanced:
            .requesting
        case .autoApprove, .autoApproveMovie, .autoApproveTV, .autoApprove4K, .autoApprove4KMovie, .autoApprove4KTV,
                .autoRequest, .autoRequestMovie, .autoRequestTV:
            .automation
        case .vote:
            .community
        }
    }

    static var editablePermissions: [SeerrPermission] {
        [
            .admin,
            .manageUsers,
            .manageRequests,
            .manageIssues,
            .viewIssues,
            .createIssues,
            .request,
            .requestMovie,
            .requestTV,
            .request4K,
            .request4KMovie,
            .request4KTV,
            .requestAdvanced,
            .requestView,
            .autoApprove,
            .autoApproveMovie,
            .autoApproveTV,
            .autoApprove4K,
            .autoApprove4KMovie,
            .autoApprove4KTV,
            .autoRequest,
            .autoRequestMovie,
            .autoRequestTV,
            .vote,
            .recentView,
            .watchlistView
        ]
    }

    static var editableGroups: [(category: SeerrPermissionCategory, permissions: [SeerrPermission])] {
        SeerrPermissionCategory.allCases.map { category in
            (
                category: category,
                permissions: editablePermissions.filter { $0.category == category }
            )
        }
    }

    static func has(_ permission: SeerrPermission, in value: Int?) -> Bool {
        guard let value else { return false }
        if value & SeerrPermission.admin.rawValue != 0 {
            return true
        }
        return value & permission.rawValue != 0
    }

    static func permissionLevelLabel(for value: Int?) -> String {
        guard let value, value > 0 else { return "Viewer" }
        if has(.admin, in: value) { return "Admin" }
        if has(.manageUsers, in: value) { return "User Manager" }
        if has(.manageIssues, in: value) { return "Issue Manager" }
        if has(.manageRequests, in: value) { return "Approver" }
        if has(.request, in: value) || has(.requestMovie, in: value) || has(.requestTV, in: value) {
            return "Requester"
        }
        return "Viewer"
    }
}

enum SeerrPermissionCategory: String, CaseIterable, Identifiable, Sendable {
    case administration = "Administration"
    case requesting = "Requesting"
    case automation = "Automation"
    case visibility = "Visibility"
    case community = "Community"

    var id: String { rawValue }
}
