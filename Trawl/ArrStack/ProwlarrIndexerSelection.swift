/// Every destination selectable in the indexer content column.
enum ProwlarrIndexerSelection: Hashable {
    case indexer(String)
    case proxies
    case tags
}
