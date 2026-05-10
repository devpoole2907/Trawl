import SwiftData

enum TrawlModelSchema {
    nonisolated static var full: Schema {
        Schema([
            ServerProfile.self,
            CachedTorrentState.self,
            RecentSavePath.self,
            ArrServiceProfile.self,
            SeerrServiceProfile.self,
            JellyfinServiceProfile.self
        ])
    }
}
