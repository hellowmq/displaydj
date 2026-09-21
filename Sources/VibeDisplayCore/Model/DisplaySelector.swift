import Foundation

/// A textual way to point at one or more displays.
///
/// Accepted forms (evaluated in this order):
///
/// | Input            | Meaning                                   |
/// |------------------|-------------------------------------------|
/// | `all`            | every online display                      |
/// | `builtin`        | the internal panel                        |
/// | `external`       | every non-internal panel                  |
/// | `main`           | the display holding the menu bar          |
/// | `#0`, `#1`       | positional index in the online list       |
/// | `id:7`           | raw CGDirectDisplayID                     |
/// | `uuid:XXXX-...`  | stable display UUID                       |
/// | anything else    | slug match, then case-insensitive name    |
///
/// Slug/name matching is exact first, then unique-prefix, then unique-substring.
/// An ambiguous match is an error, never a silent pick.
public enum DisplaySelector: Equatable, Sendable {
    case all
    case builtin
    case external
    case main
    case index(Int)
    case displayID(UInt32)
    case uuid(String)
    case token(String)

    public init(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch s.lowercased() {
        case "all", "*": self = .all; return
        case "builtin", "internal", "built-in": self = .builtin; return
        case "external", "ext": self = .external; return
        case "main", "primary": self = .main; return
        default: break
        }
        if s.hasPrefix("#"), let i = Int(s.dropFirst()) { self = .index(i); return }
        if s.lowercased().hasPrefix("id:"), let v = UInt32(s.dropFirst(3)) { self = .displayID(v); return }
        if s.lowercased().hasPrefix("uuid:") { self = .uuid(String(s.dropFirst(5))); return }
        if let i = Int(s) { self = .index(i); return }
        self = .token(s)
    }

    public var rawValue: String {
        switch self {
        case .all: return "all"
        case .builtin: return "builtin"
        case .external: return "external"
        case .main: return "main"
        case .index(let i): return "#\(i)"
        case .displayID(let v): return "id:\(v)"
        case .uuid(let u): return "uuid:\(u)"
        case .token(let t): return t
        }
    }

    /// Resolve against a snapshot of online displays.
    public func resolve(in displays: [DisplayInfo]) throws -> [DisplayInfo] {
        switch self {
        case .all:
            return displays
        case .builtin:
            let hit = displays.filter(\.isBuiltin)
            guard !hit.isEmpty else {
                throw VibeError(.displayNotFound, "no built-in display on this machine")
            }
            return hit
        case .external:
            let hit = displays.filter { !$0.isBuiltin }
            guard !hit.isEmpty else {
                throw VibeError(.displayNotFound, "no external display attached")
            }
            return hit
        case .main:
            if let hit = displays.first(where: \.isMain) { return [hit] }
            throw VibeError(.displayNotFound, "no main display reported by the window server")
        case .index(let i):
            guard let hit = displays.first(where: { $0.index == i }) else {
                throw VibeError(.displayNotFound, "no display at index \(i)",
                                hint: "run `display-cli displays` to list valid indices")
            }
            return [hit]
        case .displayID(let v):
            guard let hit = displays.first(where: { $0.id == v }) else {
                throw VibeError(.displayNotFound, "no display with CGDirectDisplayID \(v)")
            }
            return [hit]
        case .uuid(let u):
            let needle = u.lowercased()
            let matches = displays.filter { $0.uuid.lowercased() == needle }
            if matches.count > 1 { throw Self.ambiguous(u, matches) }
            guard let hit = matches.first else {
                throw VibeError(.displayNotFound, "no display with uuid \(u)")
            }
            return [hit]
        case .token(let t):
            return try resolveToken(t, in: displays)
        }
    }

    private func resolveToken(_ token: String, in displays: [DisplayInfo]) throws -> [DisplayInfo] {
        let needle = token.lowercased()

        guard !needle.isEmpty else { throw VibeError(.invalidArgument, "display selector must not be empty") }
        let slugs = displays.filter { $0.slug.lowercased() == needle }
        if slugs.count == 1 { return slugs }
        if slugs.count > 1 { throw Self.ambiguous(token, slugs) }
        let names = displays.filter { $0.name.lowercased() == needle }
        if names.count == 1 { return names }
        if names.count > 1 { throw Self.ambiguous(token, names) }

        let prefix = displays.filter { $0.slug.lowercased().hasPrefix(needle) || $0.name.lowercased().hasPrefix(needle) }
        if prefix.count == 1 { return prefix }
        if prefix.count > 1 { throw Self.ambiguous(token, prefix) }

        let substring = displays.filter { $0.slug.lowercased().contains(needle) || $0.name.lowercased().contains(needle) }
        if substring.count == 1 { return substring }
        if substring.count > 1 { throw Self.ambiguous(token, substring) }

        throw VibeError(.displayNotFound, "no display matches '\(token)'",
                        hint: "run `display-cli displays` to see slugs")
    }

    private static func ambiguous(_ token: String, _ hits: [DisplayInfo]) -> VibeError {
        VibeError(.ambiguousSelector,
                  "'\(token)' matches \(hits.count) displays: \(hits.map(\.slug).joined(separator: ", "))",
                  hint: "use a full slug, `#index`, or `uuid:<uuid>`")
    }
}

extension DisplaySelector: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
