import Foundation
import Testing
@testable import Trawl

@Suite("Multipart Request Contract Tests")
struct MultipartRequestContractTests {
    private let hostileFieldName = "restore\"\r\nX-Test: injected"
    private let hostileFilename = "backup\"\r\nX-Test: injected.zip"

    @Test("Data file parts cannot turn a hostile name or filename into another header")
    func dataFilePartSanitizesHeaderTokens() throws {
        var body = Data()
        body.appendMultipart(
            boundary: "Boundary",
            name: hostileFieldName,
            filename: hostileFilename,
            data: Data("archive".utf8)
        )

        let headerLines = try #require(headerLines(in: body))
        #expect(headerLines == [
            "--Boundary",
            "Content-Disposition: form-data; name=\"restore'X-Test: injected\"; filename=\"backup'X-Test: injected.zip\""
        ])
    }

    @Test("Data text fields cannot turn a hostile name into another header")
    func dataTextFieldSanitizesHeaderToken() throws {
        var body = Data()
        body.appendMultipartField(
            boundary: "Boundary",
            name: hostileFieldName,
            value: "value"
        )

        let headerLines = try #require(headerLines(in: body))
        #expect(headerLines == [
            "--Boundary",
            "Content-Disposition: form-data; name=\"restore'X-Test: injected\""
        ])
    }

    @Test("HTTPTransport multipart upload sends one sanitized file-part header")
    func transportVoidMultipartSanitizesOutgoingRequestBody() async throws {
        MultipartContractURLProtocol.recorder.clear()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MultipartContractURLProtocol.self]
        let transport = HTTPTransport(
            baseURL: "https://multipart.contract.test",
            auth: .none,
            sessionConfiguration: configuration,
            errorMapper: MultipartContractError.mapper
        )

        try await transport.postMultipartVoid(
            "/restore",
            fileData: Data("archive".utf8),
            fieldName: hostileFieldName,
            filename: hostileFilename
        )

        let capturedRequest = try #require(MultipartContractURLProtocol.recorder.request())
        #expect(capturedRequest.request.httpMethod == "POST")
        #expect(capturedRequest.request.url?.path == "/restore")
        let headerLines = try #require(headerLines(in: capturedRequest.body))
        #expect(headerLines.count == 3)
        #expect(headerLines[1] == "Content-Disposition: form-data; name=\"restore'X-Test: injected\"; filename=\"backup'X-Test: injected.zip\"")
        #expect(headerLines[2] == "Content-Type: application/zip")
    }

    private func headerLines(in body: Data) -> [String]? {
        let bodyString = String(data: body, encoding: .utf8)
        guard let headerBlock = bodyString?.components(separatedBy: "\r\n\r\n").first else {
            return nil
        }
        return headerBlock.components(separatedBy: "\r\n")
    }
}

private enum MultipartContractError: Error, Sendable {
    case unexpected

    static let mapper = HTTPErrorMapper(
        badURL: { MultipartContractError.unexpected },
        transport: { _ in MultipartContractError.unexpected },
        unauthorized: { MultipartContractError.unexpected },
        http: { _, _ in MultipartContractError.unexpected },
        decode: { _ in MultipartContractError.unexpected },
        invalidResponse: { MultipartContractError.unexpected },
        unauthorizedStatusCodes: []
    )
}

private final class MultipartRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedRequest: MultipartCapturedRequest?

    func record(_ request: URLRequest, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        capturedRequest = MultipartCapturedRequest(request: request, body: body)
    }

    func request() -> MultipartCapturedRequest? {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequest
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        capturedRequest = nil
    }
}

private struct MultipartCapturedRequest: Sendable {
    let request: URLRequest
    let body: Data
}

private final class MultipartContractURLProtocol: URLProtocol, @unchecked Sendable {
    static let recorder = MultipartRequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "multipart.contract.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.recorder.record(request, body: Self.readBody(from: request))
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(from request: URLRequest) -> Data {
        guard let bodyStream = request.httpBodyStream else { return Data() }
        bodyStream.open()
        defer { bodyStream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while bodyStream.hasBytesAvailable {
            let count = bodyStream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            buffer.withUnsafeBufferPointer { bytes in
                if let baseAddress = bytes.baseAddress {
                    body.append(baseAddress, count: count)
                }
            }
        }
        return body
    }
}
