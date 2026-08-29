import Foundation
import Testing
@testable import Trawl

/// Coverage for `SeerrIssueDetailViewModel` - the resolve/reopen routing, comment
/// adoption rules, and reply flow. Previously untested.
///
/// `SeerrIssueDetailViewModel` takes a real `SeerrAPIClient` directly, so these drive
/// that real client against a recording `URLProtocol` stub, following the pattern in
/// `SeerrContractTests`. The stub type here is private to this file, with its own
/// distinct host, so it cannot collide with `SeerrContractTests`' stub or with
/// `SeerrIssueListViewModelTests`' stub.
///
/// The suite is serialized because the stub protocol holds process-wide state.
@Suite("Seerr issue detail view model", .serialized)
@MainActor
struct SeerrIssueDetailViewModelTests {

    // MARK: - toggleStatus routing

    @Test("toggleStatus calls resolveIssue when the issue is currently open")
    func toggleStatusResolvesWhenOpen() async throws {
        SeerrIssueDetailStubURLProtocol.stub(body: Data(#"{"id":31,"status":2}"#.utf8))
        let viewModel = SeerrIssueDetailViewModel(issue: makeIssue(id: 31, status: 1), apiClient: makeClient())

        let result = await viewModel.toggleStatus()

        #expect(result?.id == 31)
        #expect(SeerrIssueDetailStubURLProtocol.recordedRequests.map(\.path) == ["/api/v1/issue/31/resolved"])
        #expect(SeerrIssueDetailStubURLProtocol.recordedRequests.map(\.method) == ["POST"])
    }

    @Test("toggleStatus calls reopenIssue when the issue is currently resolved")
    func toggleStatusReopensWhenResolved() async throws {
        SeerrIssueDetailStubURLProtocol.stub(body: Data(#"{"id":31,"status":1}"#.utf8))
        let viewModel = SeerrIssueDetailViewModel(issue: makeIssue(id: 31, status: 2), apiClient: makeClient())

        let result = await viewModel.toggleStatus()

        #expect(result?.id == 31)
        #expect(SeerrIssueDetailStubURLProtocol.recordedRequests.map(\.path) == ["/api/v1/issue/31/open"])
        #expect(SeerrIssueDetailStubURLProtocol.recordedRequests.map(\.method) == ["POST"])
    }

    // MARK: - toggleStatus comment adoption

    @Test("toggleStatus keeps existing comments when the response carries none")
    func toggleStatusKeepsExistingCommentsWhenResponseHasNone() async throws {
        SeerrIssueDetailStubURLProtocol.stub(body: Data(#"{"id":31,"status":2,"comments":[]}"#.utf8))
        let existingComment = SeerrIssueComment(id: 1, user: nil, message: "first", createdAt: nil, updatedAt: nil)
        let issue = makeIssue(id: 31, status: 1, comments: [existingComment])
        let viewModel = SeerrIssueDetailViewModel(issue: issue, apiClient: makeClient())
        #expect(viewModel.comments.count == 1)

        _ = await viewModel.toggleStatus()

        #expect(viewModel.comments.map(\.id) == [1])
        #expect(viewModel.issue.issueStatus == .resolved)
    }

    @Test("toggleStatus adopts the response's comments when it carries some")
    func toggleStatusAdoptsResponseCommentsWhenPresent() async throws {
        SeerrIssueDetailStubURLProtocol.stub(body: Data(#"{"id":31,"status":2,"comments":[{"id":9,"message":"resolved note"}]}"#.utf8))
        let existingComment = SeerrIssueComment(id: 1, user: nil, message: "first", createdAt: nil, updatedAt: nil)
        let issue = makeIssue(id: 31, status: 1, comments: [existingComment])
        let viewModel = SeerrIssueDetailViewModel(issue: issue, apiClient: makeClient())

        _ = await viewModel.toggleStatus()

        #expect(viewModel.comments.map(\.id) == [9])
    }

    // MARK: - sendReply

    @Test("sendReply with a whitespace-only message returns nil and makes no request")
    func sendReplyWhitespaceOnlyMakesNoRequest() async throws {
        SeerrIssueDetailStubURLProtocol.stub(body: Data(#"{"id":31}"#.utf8))
        let viewModel = SeerrIssueDetailViewModel(issue: makeIssue(id: 31, status: 1), apiClient: makeClient())
        viewModel.replyMessage = "   \n  "

        let result = await viewModel.sendReply()

        #expect(result == nil)
        #expect(SeerrIssueDetailStubURLProtocol.recordedRequests.isEmpty)
        // The guard returns before any trimming/clearing side effect.
        #expect(viewModel.replyMessage == "   \n  ")
    }

    @Test("sendReply trims the message, sends exactly the trimmed body, and clears replyMessage on success")
    func sendReplySendsTrimmedMessageAndClearsOnSuccess() async throws {
        SeerrIssueDetailStubURLProtocol.stub(body: Data(#"{"id":31,"comments":[{"id":5,"message":"hello there"}]}"#.utf8))
        let viewModel = SeerrIssueDetailViewModel(issue: makeIssue(id: 31, status: 1), apiClient: makeClient())
        viewModel.replyMessage = "  hello there  \n"

        let result = await viewModel.sendReply()

        #expect(result?.id == 31)
        #expect(viewModel.replyMessage == "")
        let recorded = try #require(SeerrIssueDetailStubURLProtocol.recordedRequests.first)
        #expect(recorded.method == "POST")
        #expect(recorded.path == "/api/v1/issue/31/comment")
        let bodyFields = try JSONSerialization.jsonObject(with: try #require(recorded.body)) as? [String: String]
        #expect(bodyFields == ["message": "hello there"])
    }

    @Test("sendReply falls back to loadComments when the reply response carries no comments")
    func sendReplyFallsBackToLoadCommentsWhenResponseHasNone() async throws {
        SeerrIssueDetailStubURLProtocol.stub(sequence: [
            .init(body: Data(#"{"id":31,"comments":[]}"#.utf8)),
            .init(body: Data(#"{"id":31,"comments":[{"id":7,"message":"loaded via GET"}]}"#.utf8))
        ])
        let viewModel = SeerrIssueDetailViewModel(issue: makeIssue(id: 31, status: 1), apiClient: makeClient())
        viewModel.replyMessage = "ping"

        _ = await viewModel.sendReply()

        #expect(SeerrIssueDetailStubURLProtocol.recordedRequests.map(\.method) == ["POST", "GET"])
        #expect(SeerrIssueDetailStubURLProtocol.recordedRequests.map(\.path) == [
            "/api/v1/issue/31/comment",
            "/api/v1/issue/31"
        ])
        #expect(viewModel.comments.map(\.id) == [7])
    }

    // MARK: - Titles (no network)

    @Test("statusTitle and toggleButtonTitle reflect the open state")
    func titlesForOpenState() {
        let viewModel = SeerrIssueDetailViewModel(issue: makeIssue(id: 1, status: 1), apiClient: SeerrAPIClient.preview())
        #expect(viewModel.statusTitle == "Open")
        #expect(viewModel.toggleButtonTitle == "Resolve Issue")
    }

    @Test("statusTitle and toggleButtonTitle reflect the resolved state")
    func titlesForResolvedState() {
        let viewModel = SeerrIssueDetailViewModel(issue: makeIssue(id: 1, status: 2), apiClient: SeerrAPIClient.preview())
        #expect(viewModel.statusTitle == "Resolved")
        #expect(viewModel.toggleButtonTitle == "Reopen Issue")
    }

    @Test("statusTitle falls back to Unknown when the issue has no status, and the toggle still targets resolve")
    func titlesForMissingStatus() {
        let viewModel = SeerrIssueDetailViewModel(issue: makeIssue(id: 1, status: nil), apiClient: SeerrAPIClient.preview())
        #expect(viewModel.statusTitle == "Unknown")
        #expect(viewModel.toggleButtonTitle == "Resolve Issue")
    }

    // MARK: - Error paths

    @Test("A failed toggleStatus sets errorMessage and leaves the issue and comments unchanged")
    func toggleStatusFailureLeavesStateIntact() async throws {
        SeerrIssueDetailStubURLProtocol.stub(statusCode: 500, body: Data(#"{"message":"boom"}"#.utf8))
        let existingComment = SeerrIssueComment(id: 1, user: nil, message: "first", createdAt: nil, updatedAt: nil)
        let issue = makeIssue(id: 31, status: 1, comments: [existingComment])
        let viewModel = SeerrIssueDetailViewModel(issue: issue, apiClient: makeClient())

        let result = await viewModel.toggleStatus()

        #expect(result == nil)
        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.issue.id == 31)
        #expect(viewModel.issue.issueStatus == .open)
        #expect(viewModel.comments.map(\.id) == [1])
    }

    @Test("A failed sendReply sets errorMessage and does not clear replyMessage")
    func sendReplyFailureLeavesStateIntact() async throws {
        SeerrIssueDetailStubURLProtocol.stub(statusCode: 500, body: Data(#"{"message":"boom"}"#.utf8))
        let viewModel = SeerrIssueDetailViewModel(issue: makeIssue(id: 31, status: 1), apiClient: makeClient())
        viewModel.replyMessage = "still here"

        let result = await viewModel.sendReply()

        #expect(result == nil)
        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.replyMessage == "still here")
    }

    @Test("clearError clears a previously set errorMessage")
    func clearErrorClearsErrorMessage() async throws {
        SeerrIssueDetailStubURLProtocol.stub(statusCode: 500, body: Data(#"{"message":"boom"}"#.utf8))
        let viewModel = SeerrIssueDetailViewModel(issue: makeIssue(id: 31, status: 1), apiClient: makeClient())
        _ = await viewModel.toggleStatus()
        #expect(viewModel.errorMessage != nil)

        viewModel.clearError()

        #expect(viewModel.errorMessage == nil)
    }

    // MARK: - Helpers

    private func makeClient() -> SeerrAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SeerrIssueDetailStubURLProtocol.self]
        return SeerrAPIClient(baseURL: "https://seerr.issuedetail.test", sessionCookie: "vm-session", sessionConfiguration: configuration)
    }

    private func makeIssue(id: Int, status: Int?, comments: [SeerrIssueComment]? = nil) -> SeerrIssue {
        SeerrIssue(
            id: id,
            issueType: 1,
            status: status,
            media: nil,
            createdBy: nil,
            modifiedBy: nil,
            comments: comments,
            createdAt: nil,
            updatedAt: nil
        )
    }
}

// MARK: - Stub server

private nonisolated struct SeerrIssueDetailRecordedRequest: Sendable, Equatable {
    let method: String
    let path: String
    let body: Data?
}

/// Recording `URLProtocol` stub for `SeerrIssueDetailViewModelTests`, copied from the
/// pattern in `SeerrContractTests.SeerrContractURLProtocol` under a distinct name and
/// host so the two - and `SeerrIssueListViewModelTests`' own stub - cannot collide.
private final class SeerrIssueDetailStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Stub: Sendable {
        var statusCode: Int = 200
        var body: Data = Data()
        var headerFields: [String: String] = ["Content-Type": "application/json"]
        var hangs: Bool = false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [Stub] = [Stub()]
    nonisolated(unsafe) private static var responseIndex = 0
    nonisolated(unsafe) private static var requests: [SeerrIssueDetailRecordedRequest] = []

    static func stub(
        statusCode: Int = 200,
        body: Data = Data(),
        headerFields: [String: String] = ["Content-Type": "application/json"],
        hangs: Bool = false
    ) {
        stub(sequence: [Stub(statusCode: statusCode, body: body, headerFields: headerFields, hangs: hangs)])
    }

    /// Responses are consumed in order; the last one repeats for any extra request.
    static func stub(sequence: [Stub]) {
        lock.lock()
        responses = sequence.isEmpty ? [Stub()] : sequence
        responseIndex = 0
        requests = []
        lock.unlock()
    }

    static var recordedRequests: [SeerrIssueDetailRecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "seerr.issuedetail.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let recorded = SeerrIssueDetailRecordedRequest(
            method: request.httpMethod ?? "",
            path: url.path,
            body: Self.bodyData(from: request)
        )

        Self.lock.lock()
        Self.requests.append(recorded)
        let stub = Self.responses[min(Self.responseIndex, Self.responses.count - 1)]
        Self.responseIndex += 1
        Self.lock.unlock()

        guard !stub.hangs else { return }

        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headerFields
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty {
            client?.urlProtocol(self, didLoad: stub.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// URLSession hands `URLProtocol` the body as a stream, so `httpBody` is nil by
    /// the time the request arrives here.
    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody { return body.isEmpty ? nil : body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4_096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}
