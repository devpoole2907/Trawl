import Foundation

extension URLSessionConfiguration {
    nonisolated static func makeTrawlSecure(timeout: TimeInterval = 30) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = timeout
        return config
    }
}
