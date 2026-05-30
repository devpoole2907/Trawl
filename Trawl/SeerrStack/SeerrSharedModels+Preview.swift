#if DEBUG
import Foundation

extension SeerrMediaRequest {
    static let preview = SeerrMediaRequest.makePreview()
    static let previewPending = SeerrMediaRequest.makePreview(id: 2, status: 1, mediaTitle: "Dune: Part Two", mediaType: "movie")
    static let previewDeclined = SeerrMediaRequest.makePreview(id: 3, status: 3, mediaTitle: "Avatar 3")
    static let previewMissingPoster = SeerrMediaRequest.makePreview(
        id: 6,
        status: 2,
        mediaTitle: "Media With Missing Poster",
        posterPath: nil
    )
    static let previewLongTitle = SeerrMediaRequest.makePreview(
        id: 7,
        status: 2,
        mediaTitle: "A Very Long Request Title That Wraps Across Multiple Lines In The Request List"
    )
    static let previewList: [SeerrMediaRequest] = [
        preview, previewPending, previewDeclined,
        .makePreview(id: 4, status: 2, mediaTitle: "Severance", mediaType: "tv"),
        .makePreview(id: 5, status: 5, mediaTitle: "Andor", mediaType: "tv"),
        previewMissingPoster,
    ]
    static let previewHeavyList: [SeerrMediaRequest] = (1...20).map { i in
        .makePreview(
            id: 100 + i,
            status: (i % 5) + 1,
            mediaTitle: i.isMultiple(of: 5) ? "A Very Long Movie Title That Should Wrap \(i)" : "Movie \(i)"
        )
    }

    fileprivate static func makePreview(
        id: Int = 1,
        status: Int = 2,
        mediaTitle: String = "The Shawshank Redemption",
        mediaType: String = "movie",
        posterPath: String? = "/q6y0Go1tsGEsmtFryDOJo3dEmqu.jpg"
    ) -> SeerrMediaRequest {
        let json: [String: Any] = [
            "id": id, "status": status,
            "is4k": false,
            "createdAt": "2024-01-15T12:00:00.000Z",
            "updatedAt": "2024-01-15T12:00:00.000Z",
            "requestedBy": [
                "id": 2,
                "displayName": "Preview User",
                "permissions": 0
            ],
            "media": [
                "id": id * 100,
                "tmdbId": 278, "mediaType": mediaType,
                "status": 5,
                "title": mediaTitle,
                "posterPath": posterPath ?? NSNull()
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: json, options: [])
        return try! JSONDecoder().decode(SeerrMediaRequest.self, from: data)
    }
}

extension SeerrMediaSummary {
    static let preview = SeerrMediaSummary(
        id: 278,
        title: "The Shawshank Redemption",
        name: nil,
        originalTitle: nil,
        originalName: nil,
        posterPath: "/q6y0Go1tsGEsmtFryDOJo3dEmqu.jpg",
        releaseDate: "1994-09-23",
        firstAirDate: nil
    )
}

extension SeerrRequestCount {
    static let preview = SeerrRequestCount(
        total: 42, movie: 18, tv: 24,
        pending: 5, approved: 30, processing: 4,
        available: 28, declined: 2, failed: 1, completed: 6
    )
    static let previewEmpty = SeerrRequestCount(
        total: 0, movie: 0, tv: 0,
        pending: 0, approved: 0, processing: 0,
        available: 0, declined: 0, failed: 0, completed: 0
    )
}

extension SeerrJob {
    static let preview = SeerrJob(
        id: "job1", name: "Check Movie Availability",
        type: "process", interval: "PT6H",
        nextExecutionTime: "2024-01-15T18:00:00.000Z", running: false
    )
    static let previewRunning = SeerrJob(
        id: "job2", name: "Refresh Media Metadata",
        type: "process", interval: "P1D",
        nextExecutionTime: nil, running: true
    )
    static let previewList: [SeerrJob] = [
        preview, previewRunning,
        .init(id: "job3", name: "Clean Up Unavailable Media", type: "process", interval: "P7D", nextExecutionTime: "2024-01-21T00:00:00.000Z", running: false),
    ]
}

extension SeerrServerLogEntry {
    static let preview = SeerrServerLogEntry.makePreview()
    static let previewList: [SeerrServerLogEntry] = [
        preview,
        .makePreview(level: "warn", message: "Radarr returned unexpected status 404"),
        .makePreview(level: "error", message: "Failed to connect to Sonarr: ECONNREFUSED"),
    ]

    fileprivate static func makePreview(
        level: String = "info",
        message: String = "Jellyfin request synced successfully",
        label: String = "SeerrService"
    ) -> SeerrServerLogEntry {
        let json: [String: Any] = [
            "label": label,
            "level": level,
            "message": message,
            "timestamp": "2024-01-15T12:00:00.000Z"
        ]
        let data = try! JSONSerialization.data(withJSONObject: json, options: [])
        return try! JSONDecoder().decode(SeerrServerLogEntry.self, from: data)
    }
}

extension SeerrJellyfinUser {
    static let preview = SeerrJellyfinUser(
        id: "jf-user-1",
        username: "preview",
        email: "preview@example.com",
        thumb: nil
    )
    static let previewList: [SeerrJellyfinUser] = [
        preview,
        .init(id: "jf-user-2", username: "alice", email: "alice@example.com", thumb: nil),
        .init(id: "jf-user-3", username: nil, email: "no-username@example.com", thumb: nil),
    ]
}

extension SeerrPublicSettings {
    static let preview = SeerrPublicSettings(
        initialized: true,
        applicationTitle: "Overseerr Preview",
        applicationUrl: "http://192.168.1.50:5055",
        hideAvailable: false,
        localLogin: true,
        mediaServerType: 2,
        partialRequestsEnabled: true
    )
}
#endif
