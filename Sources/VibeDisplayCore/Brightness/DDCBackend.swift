import Foundation
import DisplayDJCore

/// Shared DisplayDJ hardware engine, also used by the menu bar and legacy CLI.
/// Never associate a display with an IOAV service by enumeration order.
public final class DDCBackend: BrightnessBackend {
    public let transport: BrightnessTransport = .ddc
    private let readValue: @Sendable (String) async throws -> Double
    private let writeValue: @Sendable (String, Double) async throws -> Bool

    public init() {
        readValue = { selector in
            try await AppleSiliconDDCBrightnessReader().read(fromStableID: selector).value.normalized
        }
        writeValue = { selector, value in
            let result = try await AppleSiliconDDCBrightnessWriter().write(
                percent: value * 100, toStableID: selector)
            return result.wasVerified
        }
    }

    init(read: @escaping @Sendable (String) async throws -> Double,
         write: @escaping @Sendable (String, Double) async throws -> Bool) {
        readValue = read
        writeValue = write
    }

    /// Only canonical UUIDs are accepted; a synthetic or ambiguous identity fails closed.
    static func selector(for display: DisplayInfo) -> String? {
        guard !display.isBuiltin, let uuid = UUID(uuidString: display.uuid) else { return nil }
        return "uuid:\(uuid.uuidString.lowercased())"
    }

    public func supports(_ display: DisplayInfo) -> Bool {
        read(display) != nil
    }

    public func read(_ display: DisplayInfo) -> Double? {
        guard let selector = Self.selector(for: display) else { return nil }
        let reader = readValue
        guard let value = try? SynchronousTask.run({ try await reader(selector) }),
              value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }

    @discardableResult
    public func write(_ display: DisplayInfo, value: Double) -> Bool {
        guard value.isFinite, (0...1).contains(value),
              let selector = Self.selector(for: display) else { return false }
        let writer = writeValue
        return (try? SynchronousTask.run { try await writer(selector, value) }) ?? false
    }
}
