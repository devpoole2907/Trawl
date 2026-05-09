import Foundation

enum URLEncoding {
    nonisolated static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove("+")
        allowed.remove("&")
        allowed.remove("=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
    
    nonisolated static func unreservedEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
