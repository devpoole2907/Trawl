import Foundation
import Security

final class ServerTrustPolicy: NSObject, URLSessionDelegate, Sendable {
    private let allowsUntrustedTLS: Bool

    init(allowsUntrustedTLS: Bool) {
        self.allowsUntrustedTLS = allowsUntrustedTLS
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        if allowsUntrustedTLS {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
