import Foundation

nonisolated enum JSONValue: Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let x = try? container.decode(String.self) {
            self = .string(x)
        } else if let x = try? container.decode(Double.self) {
            self = .number(x)
        } else if let x = try? container.decode(Bool.self) {
            self = .bool(x)
        } else if let x = try? container.decode([String: JSONValue].self) {
            self = .object(x)
        } else if let x = try? container.decode([JSONValue].self) {
            self = .array(x)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Wrong type for JSONValue")
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let x): try container.encode(x)
        case .number(let x): try container.encode(x)
        case .bool(let x): try container.encode(x)
        case .object(let x): try container.encode(x)
        case .array(let x): try container.encode(x)
        case .null: try container.encodeNil()
        }
    }

    nonisolated var rawValue: Any {
        switch self {
        case .string(let x): return x
        case .number(let x): return x
        case .bool(let x): return x
        case .object(let x): return x.mapValues { $0.rawValue }
        case .array(let x): return x.map { $0.rawValue }
        case .null: return NSNull()
        }
    }
}

// MARK: - Preserving fields the app does not model

nonisolated extension JSONValue {
    /// `edited`, encoded, laid over the server's `current` copy of the same object so
    /// that a write keeps every field Trawl does not model.
    ///
    /// Sonarr, Radarr, Prowlarr and Jellyfin treat these updates as full
    /// replacements: a field missing from the body is reset to its default. Encoding
    /// only Trawl's model therefore wiped settings Trawl never shows - checked against
    /// live servers, an edited series lost "Monitor New Seasons", a notification lost
    /// three event toggles, a Prowlarr indexer its added date, a Jellyfin library its
    /// enabled flag and lyric/segment providers.
    ///
    /// The rule, applied at every object level: a key Trawl encodes wins; a key Trawl
    /// models but left out (a property set to nil) stays out, exactly as before; a
    /// key Trawl does not model at all is copied from `current`. "Models" is judged
    /// from the value's own stored properties, case-insensitively, so Jellyfin's
    /// PascalCase keys match their camelCase properties. Arrays are taken from the
    /// edit whole.
    static func mergingServerFields<E: Encodable>(
        _ edited: E,
        onto current: JSONValue,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> JSONValue {
        let encoded = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(edited))
        return merge(encoded, onto: current, model: edited)
    }

    private static func merge(_ encoded: JSONValue, onto current: JSONValue, model: Any?) -> JSONValue {
        guard case .object(let edits) = encoded, case .object(let server) = current else {
            return encoded
        }
        let properties = storedProperties(of: model)
        var result = edits
        for (key, value) in edits {
            if let serverValue = server[key] {
                let property: Any? = properties[key.lowercased()] ?? nil
                result[key] = merge(value, onto: serverValue, model: property)
            }
        }
        for (key, value) in server where edits[key] == nil && !properties.keys.contains(key.lowercased()) {
            result[key] = value
        }
        return .object(result)
    }

    /// A value's stored properties by lowercased name, with optionals unwrapped. Empty
    /// for anything that isn't a struct or class - a dictionary model, for instance,
    /// claims no keys, so every server key it leaves out is kept.
    private static func storedProperties(of model: Any?) -> [String: Any?] {
        guard let model = unwrap(model) else { return [:] }
        let mirror = Mirror(reflecting: model)
        guard mirror.displayStyle == .struct || mirror.displayStyle == .class else { return [:] }
        var properties: [String: Any?] = [:]
        for child in mirror.children {
            guard var label = child.label else { continue }
            if label.hasPrefix("_") { label.removeFirst() }
            // updateValue, not subscript assignment: assigning nil would drop the key,
            // and a property that is nil is still one Trawl models.
            properties.updateValue(unwrap(child.value), forKey: label.lowercased())
        }
        return properties
    }

    private static func unwrap(_ value: Any?) -> Any? {
        guard let value else { return nil }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        return mirror.children.first.map(\.value).flatMap { unwrap($0) }
    }
}
