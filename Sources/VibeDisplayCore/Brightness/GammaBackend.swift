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
    private let setTransfer: (UInt32, Float) -> Bool

    public convenience init() {
        self.init(setTransfer: { id, scale in
            CGSetDisplayTransferByFormula(id, 0, scale, 1, 0, scale, 1, 0, scale, 1) == .success
        })
    }

    init(setTransfer: @escaping (UInt32, Float) -> Bool) {
        self.setTransfer = setTransfer
    }

    public func supports(_ display: DisplayInfo) -> Bool { true }

    public func read(_ display: DisplayInfo) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return applied[display.uuid]
    }

    @discardableResult
    public func write(_ display: DisplayInfo, value: Double) -> Bool {
        let target = max(Self.floor, value.clampedBrightness)
        let scale = Float(target)
        lock.lock(); defer { lock.unlock() }
        guard setTransfer(display.id, scale) else {
            Log.debug("gamma write failed", ["display": display.slug])
            return false
        }
        applied[display.uuid] = target
        displayIDs[display.uuid] = display.id
        return true
    }

    public func release(_ display: DisplayInfo) {
        lock.lock(); defer { lock.unlock() }
        let hadEntry = applied.removeValue(forKey: display.uuid) != nil
        displayIDs.removeValue(forKey: display.uuid)
        let remaining = applied.compactMap { key, value -> (String, UInt32, Double)? in
            displayIDs[key].map { (key, $0, value) }
        }
        guard hadEntry else { return }
        CGDisplayRestoreColorSyncSettings()
        // CoreGraphics restores all tables at once; put back other displays'
        // explicitly requested dimming after releasing this one.
        for (uuid, id, value) in remaining {
            if !setTransfer(id, Float(value)) {
                applied.removeValue(forKey: uuid)
                displayIDs.removeValue(forKey: uuid)
                Log.warn("could not reapply software dimming after restoring another display")
            }
        }
    }

    /// Restore every display we touched. Called on daemon shutdown and from the
    /// signal handler, so an interrupted agent run never leaves a dim screen.
    public func releaseAll() {
        lock.lock(); defer { lock.unlock() }
        let hadAny = !applied.isEmpty
        applied.removeAll()
        displayIDs.removeAll()
        guard hadAny else { return }
        CGDisplayRestoreColorSyncSettings()
        Log.debug("gamma tables restored")
    }

    public var activeDisplayUUIDs: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(applied.keys)
    }

    /// A wake can reset process-owned color tables while the daemon remains alive.
    /// Reapply only to a currently enumerated display with the same stable UUID.
    /// A failed write is removed so `dimming get` does not report a stale value.
    @discardableResult
    public func reapplyActive(to displays: [DisplayInfo]) -> [String] {
        lock.lock(); defer { lock.unlock() }
        var restored: [String] = []
        for display in displays {
            guard let value = applied[display.uuid] else { continue }
            if setTransfer(display.id, Float(value)) {
                displayIDs[display.uuid] = display.id
                restored.append(display.uuid)
            } else {
                applied.removeValue(forKey: display.uuid)
                displayIDs.removeValue(forKey: display.uuid)
                Log.warn("software dimming could not be reapplied after wake", ["display": display.slug])
            }
        }
        return restored
    }
}
