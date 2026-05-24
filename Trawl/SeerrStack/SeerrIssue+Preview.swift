#if DEBUG
import Foundation

extension SeerrIssue {
    static let preview = SeerrIssue.makePreview()
    static let previewResolved = SeerrIssue.makePreview(id: 2, issueType: 2, status: 2)
    static let previewAudio = SeerrIssue.makePreview(id: 3, issueType: 2, mediaTitle: "Breaking Bad")
    static let previewWithComments = SeerrIssue.makePreview(
        id: 6,
        mediaTitle: "Silo",
        comments: [
            "Video drops out around the 32 minute mark.",
            "Confirmed on Apple TV and web playback.",
        ]
    )
    static let previewList: [SeerrIssue] = [
        preview, previewResolved, previewAudio, previewWithComments,
        .makePreview(id: 4, issueType: 3, mediaTitle: "The Bear"),
        .makePreview(id: 5, issueType: 4, mediaTitle: "Slow Horses"),
    ]
    static let previewHeavyList: [SeerrIssue] = (1...24).map { index in
        .makePreview(
            id: 100 + index,
            issueType: (index % 4) + 1,
            status: index.isMultiple(of: 3) ? 2 : 1,
            mediaTitle: index.isMultiple(of: 6)
                ? "Very Long Issue Media Title That Wraps Across Rows \(index)"
                : "Reported Media \(index)",
            comments: index.isMultiple(of: 4) ? ["Still happening after a metadata refresh."] : []
        )
    }

    fileprivate static func makePreview(
        id: Int = 1,
        issueType: Int = 1,
        status: Int = 1,
        mediaTitle: String = "The Shawshank Redemption",
        comments: [String] = []
    ) -> SeerrIssue {
        let json: [String: Any] = [
            "id": id,
            "issueType": issueType,
            "status": status,
            "createdAt": "2024-01-15T12:00:00.000Z",
            "updatedAt": "2024-01-15T12:00:00.000Z",
            "createdBy": [
                "id": 2,
                "displayName": "Preview User",
                "permissions": 0,
            ],
            "media": [
                "id": id * 100,
                "tmdbId": 278,
                "mediaType": "movie",
                "status": 5,
                "title": mediaTitle,
                "posterPath": "/q6y0Go1tsGEsmtFryDOJo3dEmqu.jpg",
            ],
            "comments": comments.enumerated().map { index, message in
                [
                    "id": (id * 1000) + index,
                    "message": message,
                    "createdAt": "2024-01-15T12:0\(index):00.000Z",
                    "updatedAt": "2024-01-15T12:0\(index):00.000Z",
                    "user": [
                        "id": index + 2,
                        "displayName": index == 0 ? "Preview User" : "Seerr Admin",
                        "permissions": index == 0 ? 0 : SeerrPermission.admin.rawValue,
                    ],
                ]
            },
        ]
        let data = try! JSONSerialization.data(withJSONObject: json, options: [])
        return try! JSONDecoder().decode(SeerrIssue.self, from: data)
    }
}

extension SeerrIssueComment {
    static let preview = SeerrIssueComment.makePreview()
    static let previewStaffReply = SeerrIssueComment.makePreview(
        id: 2,
        userName: "Seerr Admin",
        message: "I refreshed metadata and queued a replacement file."
    )
    static let previewList: [SeerrIssueComment] = [preview, previewStaffReply]

    fileprivate static func makePreview(
        id: Int = 1,
        userName: String = "Preview User",
        message: String = "This item has playback artifacts near the end.",
        createdAt: String = "2024-01-15T12:00:00.000Z"
    ) -> SeerrIssueComment {
        let json: [String: Any] = [
            "id": id,
            "message": message,
            "createdAt": createdAt,
            "updatedAt": createdAt,
            "user": [
                "id": id,
                "displayName": userName,
                "permissions": userName == "Seerr Admin" ? SeerrPermission.admin.rawValue : 0,
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: json, options: [])
        return try! JSONDecoder().decode(SeerrIssueComment.self, from: data)
    }
}
#endif
