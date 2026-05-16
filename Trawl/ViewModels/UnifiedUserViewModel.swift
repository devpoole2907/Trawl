import Foundation
import Observation

@MainActor
@Observable
final class UnifiedUserViewModel {
    struct UnifiedUser: Identifiable, Sendable {
        var id: String
        var jellyfinUser: JellyfinUser?
        var seerrUser: SeerrUser?

        var displayName: String {
            jellyfinUser?.name ?? seerrUser?.displayName ?? "Unknown"
        }

        var isInJellyfin: Bool { jellyfinUser != nil }
        var isInSeerr: Bool { seerrUser != nil }

        func avatarURL(seerrBaseURL: String?) -> URL? {
            seerrUser?.avatarURL(baseURL: seerrBaseURL)
        }
    }

    private(set) var users: [UnifiedUser] = []
    private(set) var isLoading = false
    private(set) var jellyfinLoadError: String?
    private(set) var seerrLoadError: String?

    let jellyfinClient: JellyfinAPIClient
    let seerrClient: SeerrAPIClient?

    private var hasLoaded = false

    init(jellyfinClient: JellyfinAPIClient, seerrClient: SeerrAPIClient?) {
        self.jellyfinClient = jellyfinClient
        self.seerrClient = seerrClient
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    func load() async {
        isLoading = true
        jellyfinLoadError = nil
        seerrLoadError = nil

        async let jellyfinTask: [JellyfinUser] = fetchJellyfinUsers()
        async let seerrTask: [SeerrUser] = fetchAllSeerrUsers()

        let (jellyfinUsers, seerrUsers) = await (jellyfinTask, seerrTask)
        users = merged(jellyfinUsers: jellyfinUsers, seerrUsers: seerrUsers)
        hasLoaded = true
        isLoading = false
    }

    private func fetchJellyfinUsers() async -> [JellyfinUser] {
        do {
            return try await jellyfinClient.getUsers()
        } catch {
            jellyfinLoadError = error.localizedDescription
            return []
        }
    }

    private func fetchAllSeerrUsers() async -> [SeerrUser] {
        guard let client = seerrClient else { return [] }
        var all: [SeerrUser] = []
        var skip = 0
        let pageSize = 50
        while true {
            do {
                let response = try await client.getUsers(take: pageSize, skip: skip)
                all.append(contentsOf: response.results)
                let total = response.pageInfo.results ?? response.results.count
                if all.count >= total || response.results.isEmpty { break }
                skip += pageSize
            } catch {
                if all.isEmpty { seerrLoadError = error.localizedDescription }
                break
            }
        }
        return all
    }

    private func merged(jellyfinUsers: [JellyfinUser], seerrUsers: [SeerrUser]) -> [UnifiedUser] {
        var result: [UnifiedUser] = []
        var matchedJellyfinIDs = Set<String>()

        for seerrUser in seerrUsers {
            let match = jellyfinUsers.first { jf in
                if let jfUsername = seerrUser.jellyfinUsername, !jfUsername.isEmpty {
                    return jf.name.caseInsensitiveCompare(jfUsername) == .orderedSame
                }
                if let username = seerrUser.username, !username.isEmpty {
                    return jf.name.caseInsensitiveCompare(username) == .orderedSame
                }
                return false
            }
            let uid = match?.id ?? "seerr-\(seerrUser.id)"
            result.append(UnifiedUser(id: uid, jellyfinUser: match, seerrUser: seerrUser))
            if let jid = match?.id { matchedJellyfinIDs.insert(jid) }
        }

        for jf in jellyfinUsers where !matchedJellyfinIDs.contains(jf.id) {
            result.append(UnifiedUser(id: jf.id, jellyfinUser: jf, seerrUser: nil))
        }

        return result.sorted {
            $0.displayName.caseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func applyUpdatedJellyfinUser(_ user: JellyfinUser) {
        if let index = users.firstIndex(where: { $0.jellyfinUser?.id == user.id }) {
            users[index].jellyfinUser = user
        }
    }

    func applyUpdatedSeerrUser(_ user: SeerrUser) {
        if let index = users.firstIndex(where: { $0.seerrUser?.id == user.id }) {
            users[index].seerrUser = user
        } else {
            applySeerrImport([user])
        }
    }

    func removeJellyfinUser(_ user: JellyfinUser) {
        if let index = users.firstIndex(where: { $0.jellyfinUser?.id == user.id }) {
            if let seerrUser = users[index].seerrUser {
                users[index].jellyfinUser = nil
                users[index].id = "seerr-\(seerrUser.id)"
            } else {
                users.remove(at: index)
            }
        }
    }

    func removeSeerrUser(_ user: SeerrUser) {
        if let index = users.firstIndex(where: { $0.seerrUser?.id == user.id }) {
            if users[index].jellyfinUser != nil {
                users[index].seerrUser = nil
            } else {
                users.remove(at: index)
            }
        }
    }

    func addCreatedJellyfinUser(_ user: JellyfinUser) {
        if let index = users.firstIndex(where: {
            $0.jellyfinUser == nil &&
            ($0.seerrUser?.jellyfinUsername.map { $0.caseInsensitiveCompare(user.name) == .orderedSame } == true ||
             $0.seerrUser?.username.map { $0.caseInsensitiveCompare(user.name) == .orderedSame } == true)
        }) {
            users[index].jellyfinUser = user
            users[index].id = user.id
        } else {
            users.append(UnifiedUser(id: user.id, jellyfinUser: user, seerrUser: nil))
            users.sort { $0.displayName.caseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
    }

    func applySeerrImport(_ seerrUsers: [SeerrUser]) {
        for seerrUser in seerrUsers {
            let jfUsername = seerrUser.jellyfinUsername ?? ""
            let username = seerrUser.username ?? ""
            if let index = users.firstIndex(where: {
                $0.seerrUser == nil &&
                (!jfUsername.isEmpty && $0.jellyfinUser?.name.caseInsensitiveCompare(jfUsername) == .orderedSame ||
                 !username.isEmpty && $0.jellyfinUser?.name.caseInsensitiveCompare(username) == .orderedSame)
            }) {
                users[index].seerrUser = seerrUser
            } else {
                users.append(UnifiedUser(id: "seerr-\(seerrUser.id)", jellyfinUser: nil, seerrUser: seerrUser))
                users.sort { $0.displayName.caseInsensitiveCompare($1.displayName) == .orderedAscending }
            }
        }
    }
}
