import Foundation
import Network
import Testing
@testable import Trawl

/// Jellyfin's user administration had no coverage at any level, while Seerr's
/// equivalents are covered in `SeerrContractTests`. These are the highest-consequence
/// mutations the app can make against a Jellyfin server: a policy decides what a person
/// can watch, download, delete and administer, and deleting a user is irreversible from
/// inside Trawl.
///
/// The specific hazard is that `POST /Users/{id}/Policy` replaces the **whole** policy.
/// Jellyfin does not merge - whatever is sent becomes the user's permissions. So an
/// editor that rebuilt the policy from the fields it happens to show would silently
/// clear every permission it does not know about, and the UI would look correct
/// afterwards because it only renders the fields it knows. `JellyfinUserEditorViewModel`
/// avoids that by seeding `policy` from the user's existing policy and mutating it in
/// place; these tests pin that, because nothing about the screen would reveal a
/// regression.
@Suite("Jellyfin user policy and deletion", .serialized)
@MainActor
struct JellyfinUserPolicyTests {

    @Test("Toggling one permission preserves every other field in the policy that is sent")
    func editingOnePermissionPreservesTheRest() async throws {
        let server = try await JellyfinFixtureServer(label: "jf-policy-preserve") { request in
            switch (request.method, request.path) {
            case ("POST", "/Users/u1/Policy"):
                return .noContent
            case ("GET", "/Users"):
                return .json("[\(richUserJSON)]")
            default:
                return .json("{}")
            }
        }
        defer { server.stop() }

        let user = try JSONDecoder().decode(JellyfinUser.self, from: Data(richUserJSON.utf8))
        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")
        let viewModel = JellyfinUserEditorViewModel(user: user, apiClient: client)

        // The one change a user makes on screen.
        viewModel.policy.enableContentDownloading = false

        let refreshed = await viewModel.save()
        #expect(refreshed != nil)

        let policyPost = try #require(server.requests.first { $0.method == "POST" && $0.path == "/Users/u1/Policy" })
        let body = try #require(
            try JSONSerialization.jsonObject(with: Data(policyPost.body.utf8)) as? [String: Any]
        )

        // The edit itself.
        #expect(body["EnableContentDownloading"] as? Bool == false)

        // Everything the editor did not touch must survive the round trip. These are the
        // fields that decide whether someone keeps admin rights, keeps access to their
        // libraries, and stays un-disabled - silently dropping any of them is the
        // failure this test exists for.
        #expect(body["IsAdministrator"] as? Bool == true)
        #expect(body["IsDisabled"] as? Bool == false)
        #expect(body["EnableMediaPlayback"] as? Bool == true)
        #expect(body["EnableLiveTvAccess"] as? Bool == true)
        #expect(body["EnableRemoteAccess"] as? Bool == true)
        #expect(body["EnableContentDeletion"] as? Bool == true)
        #expect(body["MaxParentalRating"] as? Int == 13)
        #expect(body["EnabledFolders"] as? [String] == ["folder-a", "folder-b"])
        #expect(body["EnableContentDeletionFromFolders"] as? [String] == ["folder-a"])
        #expect(body["BlockedTags"] as? [String] == ["horror"])
    }

    @Test("A rejected policy update reports the failure and keeps the edit pending")
    func rejectedPolicyUpdateKeepsTheEditPending() async throws {
        let server = try await JellyfinFixtureServer(label: "jf-policy-reject") { request in
            switch (request.method, request.path) {
            case ("POST", "/Users/u1/Policy"):
                return .json(#"{"error":"nope"}"#, status: 500)
            default:
                return .json("{}")
            }
        }
        defer { server.stop() }

        let user = try JSONDecoder().decode(JellyfinUser.self, from: Data(richUserJSON.utf8))
        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")
        let viewModel = JellyfinUserEditorViewModel(user: user, apiClient: client)

        viewModel.policy.isAdministrator = false

        let refreshed = await viewModel.save()

        #expect(refreshed == nil)
        #expect(viewModel.errorMessage != nil, "A rejected policy update must be surfaced, not swallowed.")
        #expect(
            viewModel.hasChanges,
            "The edit must stay pending after a failed save: reporting it as saved would leave the admin believing a permission change took effect on the server when it did not."
        )
        #expect(
            viewModel.policy.isAdministrator == false,
            "The user's unsaved edit must not be reverted underneath them by a failed save."
        )
    }

    @Test("Deleting a user targets exactly that user with an authenticated DELETE")
    func deleteUserTargetsThatUser() async throws {
        let server = try await JellyfinFixtureServer(label: "jf-user-delete") { request in
            request.method == "DELETE" && request.path == "/Users/u1" ? .noContent : .json("{}")
        }
        defer { server.stop() }

        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")

        try await client.deleteUser(id: "u1")

        let requests = server.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.method == "DELETE")
        #expect(request.path == "/Users/u1")
        #expect(request.body.isEmpty, "A user deletion carries no body - anything here would be sent to the server unread.")
        #expect(
            request.authorization?.contains("jf-token") == true,
            "The deletion must be authenticated; an unauthenticated one would fail on a real server."
        )
    }

    @Test("A rejected deletion surfaces as an error rather than reporting success")
    func rejectedDeletionThrows() async throws {
        let server = try await JellyfinFixtureServer(label: "jf-user-delete-reject") { _ in
            .json(#"{"error":"forbidden"}"#, status: 403)
        }
        defer { server.stop() }

        let client = JellyfinAPIClient(baseURL: server.baseURL, accessToken: "jf-token")

        await #expect(throws: (any Error).self) {
            try await client.deleteUser(id: "u1")
        }
        #expect(server.requests.contains { $0.method == "DELETE" && $0.path == "/Users/u1" })
    }
}

/// A user whose policy has many fields set, so "the editor preserved what it did not
/// touch" is actually observable. A sparse policy would pass the preservation test
/// without proving anything.
///
/// File scope rather than a static on the suite: the suite is `@MainActor`, and the
/// fixture server's router closure is `@Sendable`.
private let richUserJSON = """
{
  "Id": "u1",
  "Name": "ada",
  "ServerId": "srv-1",
  "HasPassword": true,
  "Policy": {
    "IsAdministrator": true,
    "IsHidden": false,
    "IsDisabled": false,
    "EnableContentDeletion": true,
    "EnableContentDeletionFromFolders": ["folder-a"],
    "EnableContentDownloading": true,
    "EnableMediaPlayback": true,
    "EnableLiveTvAccess": true,
    "EnableRemoteAccess": true,
    "MaxParentalRating": 13,
    "EnabledFolders": ["folder-a", "folder-b"],
    "BlockedTags": ["horror"]
  }
}
"""
