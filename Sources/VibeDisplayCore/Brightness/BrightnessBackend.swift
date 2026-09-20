import Foundation

/// One physical way of changing brightness.
///
/// Backends are probed in priority order by `BrightnessService`; the first one
/// that claims a display wins. Every backend must be safe to call on a display
/// it does not support (return `false` / `nil`, never crash).
public protocol BrightnessBackend: AnyObject {
    var transport: BrightnessTransport { get }

    /// Cheap, side-effect-free check. Called during capability probing.
    func supports(_ display: DisplayInfo) -> Bool

    /// Current brightness in 0...1, or `nil` if this backend cannot read it.
    func read(_ display: DisplayInfo) -> Double?

    /// Apply brightness in 0...1. Returns `false` on failure.
    @discardableResult
    func write(_ display: DisplayInfo, value: Double) -> Bool

    /// Release anything the backend is holding for this display (gamma tables,
    /// I2C handles). Called on shutdown and on display disconnect.
    func release(_ display: DisplayInfo)
}

public extension BrightnessBackend {
    func release(_ display: DisplayInfo) {}
}

/// Tiny wrapper around `dlopen`/`dlsym` so private-framework access stays in
/// one auditable place. See `docs/ARCHITECTURE.md#private-api-policy`.
enum DynamicSymbol {
    private static var handles: [String: UnsafeMutableRawPointer] = [:]
    private static let lock = NSLock()

    static func handle(_ path: String) -> UnsafeMutableRawPointer? {
        lock.lock(); defer { lock.unlock() }
        if let existing = handles[path] { return existing }
        guard let h = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else { return nil }
        handles[path] = h
        return h
    }

    static func lookup(_ name: String, in path: String) -> UnsafeMutableRawPointer? {
        guard let h = handle(path) else { return nil }
        return dlsym(h, name)
    }
}
