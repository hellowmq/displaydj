import Foundation
import CoreGraphics

/// Software dimming via the display gamma ramp. The universal fallback: it
/// works on every panel, including HDMI/USB-C monitors that refuse DDC and
/// virtual displays.
///
/// ## The resident-process caveat
///
/// CoreGraphics scopes gamma tables to the process that installed them. When
/// that process exits, the window server restores the ColorSync profile. So a
/// one-shot `display-cli brightness set` that lands on this backend would
/// visually "snap back" the instant the command returns.
///
/// display-cli handles this by routing gamma writes through the resident
/// daemon (`display-cli serve`). The CLI detects the situation and either
/// forwards the call or tells the user to start the daemon — it never silently
/// does nothing. See `docs/ARCHITECTURE.md#gamma-caveat`.
public final class GammaBackend: BrightnessBackend {
    public let transport: BrightnessTransport = .gamma

    /// Never fully black out a display — an agent bug should not leave the user
    /// staring at an unrecoverable screen.
    public static let floor: Double = 0.08

    private let lock = NSLock()
    private var applied: [String: Double] = [:]
    private var displayIDs: [String: UInt32] = [:]

    public init() {}

    public func supports(_ display: DisplayInfo) -> Bool { true }

    public func read(_ display: DisplayInfo) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return applied[display.uuid]
    }

    @discardableResult
    public func write(_ display: DisplayInfo, value: Double) -> Bool {
        let target = max(Self.floor, value.clampedBrightness)
        let scale = Float(target)
        let err = CGSetDisplayTransferByFormula(
            display.id,
            0.0, scale, 1.0,
            0.0, scale, 1.0,
            0.0, scale, 1.0
        )
        guard err == .success else {
            Log.debug("gamma write failed", ["display": display.slug, "cgerror": "\(err.rawValue)"])
            return false
        }
        lock.lock()
        applied[display.uuid] = target
        displayIDs[display.uuid] = display.id
        lock.unlock()
        return true
    }

    public func release(_ display: DisplayInfo) {
        lock.lock()
        let hadEntry = applied.removeValue(forKey: display.uuid) != nil
        displayIDs.removeValue(forKey: display.uuid)
        lock.unlock()
        guard hadEntry else { return }
        CGDisplayRestoreColorSyncSettings()
    }

    /// Restore every display we touched. Called on daemon shutdown and from the
    /// signal handler, so an interrupted agent run never leaves a dim screen.
    public func releaseAll() {
        lock.lock()
        let hadAny = !applied.isEmpty
        applied.removeAll()
        displayIDs.removeAll()
        lock.unlock()
        guard hadAny else { return }
        CGDisplayRestoreColorSyncSettings()
        Log.debug("gamma tables restored")
    }

    public var activeDisplayUUIDs: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(applied.keys)
    }
}
