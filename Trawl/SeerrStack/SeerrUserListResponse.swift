import Foundation

struct SeerrUserListResponse: Codable, Sendable {
    let pageInfo: SeerrPageInfo
    let results: [SeerrUser]
}