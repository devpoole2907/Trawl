import Foundation

/// Request timeouts, split by who is waiting on the answer.
///
/// A person who just tapped something will wait; a poller will not, because
/// another cycle is along shortly and a request still hanging when the next one
/// starts is only ever going to collide with it. The long timeout stays where the
/// work genuinely takes time - uploading a `.torrent` or an NZB over a slow link -
/// and the short one goes on the automatic cycles, so a server that accepts
/// connections and then says nothing stalls a poll for ten seconds rather than
/// half a minute.
nonisolated enum TrawlTimeout {
    /// Automatic, repeating background refreshes.
    static let poll: TimeInterval = 10
    /// Anything a person is waiting on, including uploads.
    static let userAction: TimeInterval = 30
}

extension URLSessionConfiguration {
    nonisolated static func makeTrawlSecure(timeout: TimeInterval = TrawlTimeout.userAction) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = timeout
        return config
    }
}
