import Foundation
import Testing
@testable import Trawl

@Suite("HTTPTransport Contract Tests")
struct HTTPTransportContractTests {
    @Test("GET builds the expected URL, query, auth header, and decodes JSON")
    func getBuildsAndDecodesRequest() async throws {
        let token = "successful-request"
        HTTPTransportContractURLProtocol.recorder.removeRequest(for: token)
        let transport = makeTransport(token: token, auth: .staticHeader(name: "X-Api-Key", value: "secret-key"))

        let response: HTTPTransportFixture = try await transport.get(
            "/api/items",
            queryItems: [
                URLQueryItem(name: "title", value: "The Expanse"),
                URLQueryItem(name: "tag", value: "4K")
            ]
        )

        #expect(response == HTTPTransportFixture(name: "Trawl", count: 2))
        let request = try #require(HTTPTransportContractURLProtocol.recorder.request(for: token))
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/\(token)/api/items")
        #expect(URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems == [
            URLQueryItem(name: "title", value: "The Expanse"),
            URLQueryItem(name: "tag", value: "4K")
        ])
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "secret-key")
    }

    @Test("maps unauthorized and HTTP failure status codes", arguments: [401, 404, 429, 500])
    func mapsFailureStatuses(status: Int) async throws {
        let transport = makeTransport(token: "status-\(status)")

        do {
            try await transport.getVoid("/status/\(status)")
            Issue.record("Expected HTTPTransport to reject status \(status).")
        } catch let error as HTTPTransportContractError {
            switch status {
            case 401:
                #expect(error == .unauthorized)
            default:
                #expect(error == .http(status: status, body: "status \(status)"))
            }
        } catch {
            Issue.record("Expected HTTPTransportContractError, received \(error).")
        }
    }

    @Test("rejects a final redirect response")
    func rejectsFinalRedirectResponse() async throws {
        let transport = makeTransport(token: "final-redirect")

        do {
            try await transport.getVoid("/status/302")
            Issue.record("Expected HTTPTransport to reject a final 302 response.")
        } catch let error as HTTPTransportContractError {
            #expect(error == .http(status: 302, body: "status 302"))
        } catch {
            Issue.record("Expected HTTPTransportContractError, received \(error).")
        }
    }

    private func makeTransport(token: String, auth: HTTPAuth = .none) -> HTTPTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPTransportContractURLProtocol.self]
        return HTTPTransport(
            baseURL: "https://http-transport.contract.test/\(token)",
            auth: auth,
            sessionConfiguration: configuration,
            errorMapper: HTTPTransportContractError.mapper
        )
    }
}

private struct HTTPTransportFixture: Codable, Equatable {
    let name: String
    let count: Int
}

private enum HTTPTransportContractError: Error, Equatable, Sendable {
    case badURL
    case transport
    case unauthorized
    case http(status: Int, body: String?)
    case decode
    case invalidResponse

    static let mapper = HTTPErrorMapper(
        badURL: { HTTPTransportContractError.badURL },
        transport: { _ in HTTPTransportContractError.transport },
        unauthorized: { HTTPTransportContractError.unauthorized },
        http: { status, body in HTTPTransportContractError.http(status: status, body: body) },
        decode: { _ in HTTPTransportContractError.decode },
        invalidResponse: { HTTPTransportContractError.invalidResponse },
        unauthorizedStatusCodes: [401]
    )
}

private final class HTTPTransportRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [String: URLRequest] = [:]

    func record(_ request: URLRequest, token: String) {
        lock.lock()
        defer { lock.unlock() }
        requests[token] = request
    }

    func request(for token: String) -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requests[token]
    }

    func removeRequest(for token: String) {
        lock.lock()
        defer { lock.unlock() }
        requests.removeValue(forKey: token)
    }
}

private final class HTTPTransportContractURLProtocol: URLProtocol, @unchecked Sendable {
    static let recorder = HTTPTransportRequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "http-transport.contract.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let pathComponents = url.path.split(separator: "/").map(String.init)
        guard let token = pathComponents.first else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.recorder.record(request, token: token)

        let status = Int(pathComponents.last ?? "") ?? 200
        let body: Data
        if url.path.contains("/status/") {
            body = Data("status \(status)".utf8)
        } else {
            body = Data("{\"name\":\"Trawl\",\"count\":2}".utf8)
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
