import Foundation
import Security

final class ServerTrustPolicy: NSObject, URLSessionDelegate, URLSessionTaskDelegate, Sendable {
    private let allowsUntrustedTLS: Bool

    /// Headers stripped on cross-host redirects so an attacker controlling a
    /// redirector cannot exfiltrate a Trawl-managed API key or session cookie
    /// to an unrelated host.
    private static let sensitiveHeaders: Set<String> = [
        "Authorization",
        "X-Api-Key",
        "X-API-KEY",
        "Cookie"
    ]

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

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let originalHost = task.originalRequest?.url?.host?.lowercased()
        let newHost = request.url?.host?.lowercased()
        guard originalHost != newHost else {
            completionHandler(request)
            return
        }
        var sanitized = request
        for header in Self.sensitiveHeaders {
            sanitized.setValue(nil, forHTTPHeaderField: header)
        }
        completionHandler(sanitized)
    }
}
