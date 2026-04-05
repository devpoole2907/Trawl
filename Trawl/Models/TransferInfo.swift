import Foundation

struct TransferInfo: Codable, Sendable {
    let dlInfoSpeed: Int64
    let dlInfoData: Int64
    let upInfoSpeed: Int64
    let upInfoData: Int64
    let dlRateLimit: Int64
    let upRateLimit: Int64
    let dhtNodes: Int
    let connectionStatus: String

    enum CodingKeys: String, CodingKey {
        case dlInfoSpeed = "dl_info_speed"
        case dlInfoData = "dl_info_data"
        case upInfoSpeed = "up_info_speed"
        case upInfoData = "up_info_data"
        case dlRateLimit = "dl_rate_limit"
        case upRateLimit = "up_rate_limit"
        case dhtNodes = "dht_nodes"
        case connectionStatus = "connection_status"
    }

    nonisolated init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dlInfoSpeed = try c.decode(Int64.self, forKey: .dlInfoSpeed)
        dlInfoData = try c.decode(Int64.self, forKey: .dlInfoData)
        upInfoSpeed = try c.decode(Int64.self, forKey: .upInfoSpeed)
        upInfoData = try c.decode(Int64.self, forKey: .upInfoData)
        dlRateLimit = try c.decode(Int64.self, forKey: .dlRateLimit)
        upRateLimit = try c.decode(Int64.self, forKey: .upRateLimit)
        dhtNodes = try c.decode(Int.self, forKey: .dhtNodes)
        connectionStatus = try c.decode(String.self, forKey: .connectionStatus)
    }
}
