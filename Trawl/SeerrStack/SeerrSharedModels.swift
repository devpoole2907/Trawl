import Foundation

struct SeerrPageInfo: Codable, Sendable {
    let pages: Int?
    let pageSize: Int?
    let results: Int?
    let page: Int?
}

struct SeerrRequestCount: Codable, Sendable {
    let total: Int?
    let movie: Int?
    let tv: Int?
    let pending: Int?
    let approved: Int?
    let processing: Int?
    let available: Int?
    let declined: Int?
    let failed: Int?
    let completed: Int?
}
