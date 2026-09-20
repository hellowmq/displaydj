import Foundation
import VibeDisplayCore

/// Hand-rolled argument parsing.
///
/// The main CLI preserves its dependency-free parser and original grammar.
/// The separate displaydj compatibility executable uses swift-argument-parser.
///
/// Grammar:
/// ```text
///   display-cli [global-flags] <command> [subcommand] [args] [--opt v] [--flag] [-- passthrough...]
/// ```
struct Arguments {
    private(set) var positionals: [String] = []
    private(set) var options: [String: String] = [:]
    private(set) var flags: Set<String> = []
    /// Everything after a bare `--`, handed to `agent run` verbatim.
    private(set) var passthrough: [String] = []

    /// Options that always take a value. Anything else starting with `--` and
    /// not in this set is treated as a boolean flag unless written `--k=v`.
    static let valueOptions: Set<String> = [
        "display", "d", "selector", "ramp", "ttl", "scope", "reason", "owner",
        "label", "client", "outcome", "note", "phase", "port", "host", "window",
        "id", "config", "format", "timeout", "metadata", "beat", "on-fail"
    ]

    init(_ argv: [String]) {
        var iterator = argv.makeIterator()
        var afterDoubleDash = false

        while let token = iterator.next() {
            if afterDoubleDash {
                passthrough.append(token)
                continue
            }
            if token == "--" {
                afterDoubleDash = true
                continue
            }
            if token.hasPrefix("--") {
                let body = String(token.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    options[String(body[body.startIndex..<eq])] = String(body[body.index(after: eq)...])
                } else if Self.valueOptions.contains(body) {
                    options[body] = iterator.next() ?? ""
                } else {
                    flags.insert(body)
                }
                continue
            }
            if token.hasPrefix("-"), token.count > 1, !token.dropFirst().allSatisfy({ $0.isNumber || $0 == "." || $0 == "%" }) {
                let body = String(token.dropFirst())
                if Self.valueOptions.contains(body) {
                    options[body] = iterator.next() ?? ""
                } else {
                    flags.insert(body)
                }
                continue
            }
            positionals.append(token)
        }
    }

    func positional(_ index: Int) -> String? {
        index < positionals.count ? positionals[index] : nil
    }

    func string(_ names: String...) -> String? {
        for name in names {
            if let value = options[name] { return value }
        }
        return nil
    }

    func int(_ names: String...) -> Int? {
        for name in names {
            if let raw = options[name] { return Int(raw) }
        }
        return nil
    }

    func has(_ names: String...) -> Bool {
        names.contains { flags.contains($0) }
    }

    /// `--metadata k=v,k2=v2`
    func metadata() -> [String: String] {
        guard let raw = string("metadata") else { return [:] }
        var out: [String: String] = [:]
        for pair in raw.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            out[String(kv[0]).trimmingCharacters(in: .whitespaces)] =
                String(kv[1]).trimmingCharacters(in: .whitespaces)
        }
        return out
    }
}

/// Shared output helpers so `--json` behaves identically in every command.
enum Output {
    nonisolated(unsafe) static var json = false

    static func emit<T: Encodable>(_ payload: T, human: () -> String) {
        if json {
            print(JSONCoding.string(VibeResponse(data: AnyEncodableBox(payload))))
        } else {
            let text = human()
            if !text.isEmpty { print(text) }
        }
    }

    static func fail(_ error: VibeError) -> Never {
        if json {
            print(JSONCoding.string(VibeResponse<EmptyPayload>(error: error)))
        } else {
            FileHandle.standardError.write(Data(("error: " + error.description + "\n").utf8))
        }
        exit(error.exitCode)
    }

    static func note(_ message: String) {
        guard !json else { return }
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

/// Type erasure so `Output.emit` can wrap any payload in the standard envelope.
struct AnyEncodableBox: Encodable {
    private let encodeImpl: (Encoder) throws -> Void

    init<T: Encodable>(_ wrapped: T) {
        encodeImpl = { encoder in try wrapped.encode(to: encoder) }
    }

    func encode(to encoder: Encoder) throws {
        try encodeImpl(encoder)
    }
}

/// Fixed-width table rendering for human output.
enum Table {
    static func render(headers: [String], rows: [[String]]) -> String {
        guard !rows.isEmpty else { return "(none)" }
        var widths = headers.map { $0.count }
        for row in rows {
            for (i, cell) in row.enumerated() where i < widths.count {
                widths[i] = max(widths[i], cell.count)
            }
        }
        func line(_ cells: [String]) -> String {
            cells.enumerated()
                .map { i, cell in cell.padding(toLength: widths[i], withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
                .trimmingCharacters(in: .whitespaces)
        }
        var out = [line(headers), widths.map { String(repeating: "-", count: $0) }.joined(separator: "  ")]
        out.append(contentsOf: rows.map(line))
        return out.joined(separator: "\n")
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "-" }
        return String(format: "%3.0f%%", value * 100)
    }
}
