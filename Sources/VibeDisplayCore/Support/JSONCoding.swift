import Foundation

public enum JSONCoding {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let compactEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static func string<T: Encodable>(_ value: T, pretty: Bool = true) -> String {
        let enc = pretty ? encoder : compactEncoder
        guard let data = try? enc.encode(value),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

/// Uniform envelope for every machine-readable response, on both CLI (`--json`)
/// and HTTP. Agents can rely on `ok` alone to decide success.
///
/// Encode-only by design: the producer side is the only side that needs the
/// generic. Consumers decode with `VibeDecodedResponse` or, in the CLI's case,
/// pull `data` out with `JSONSerialization` and decode the concrete payload.
public struct VibeResponse<T: Encodable>: Encodable {
    public let ok: Bool
    public let data: T?
    public let error: VibeError?

    private enum CodingKeys: String, CodingKey { case ok, data, error }

    public init(data: T) {
        self.ok = true
        self.data = data
        self.error = nil
    }

    public init(error: VibeError) {
        self.ok = false
        self.data = nil
        self.error = error
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ok, forKey: .ok)
        try container.encodeIfPresent(data, forKey: .data)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

/// Decoding counterpart, used by tests and by any Swift consumer of the API.
public struct VibeDecodedResponse<T: Decodable>: Decodable {
    public let ok: Bool
    public let data: T?
    public let error: VibeError?
}

/// Placeholder payload for endpoints that return no data.
public struct EmptyPayload: Codable {
    public init() {}
}
