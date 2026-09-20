import Foundation
import CoreGraphics

/// Backlight control for Apple internal panels.
///
/// macOS exposes no public API for setting built-in display brightness, so we
/// resolve three symbols from the private `DisplayServices` framework at
/// runtime. Every call site degrades gracefully: if a symbol is missing on a
/// future macOS release, `supports()` returns `false` and `BrightnessService`
/// silently falls through to the gamma backend.
///
/// Policy: we only *resolve* private symbols, never link against them, and we
/// never ship headers copied from Apple. See docs/ARCHITECTURE.md.
public final class DisplayServicesBackend: BrightnessBackend {
    public let transport: BrightnessTransport = .displayServices

    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32
    private typealias CanFn = @convention(c) (UInt32) -> Bool
    private typealias NotifyFn = @convention(c) (UInt32, Double) -> Void

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"

    private let getFn: GetFn?
    private let setFn: SetFn?
    private let canFn: CanFn?
    private let notifyFn: NotifyFn?

    public private(set) var isAvailable: Bool

    public init() {
        func sym(_ name: String) -> UnsafeMutableRawPointer? {
            DynamicSymbol.lookup(name, in: Self.frameworkPath)
        }
        getFn = sym("DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetFn.self) }
        setFn = sym("DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetFn.self) }
        canFn = sym("DisplayServicesCanChangeBrightness").map { unsafeBitCast($0, to: CanFn.self) }
        notifyFn = sym("DisplayServicesBrightnessChanged").map { unsafeBitCast($0, to: NotifyFn.self) }
        isAvailable = (getFn != nil && setFn != nil)
        if !isAvailable {
            Log.debug("DisplayServices symbols unavailable; internal panel will use gamma fallback")
        }
    }

    public func supports(_ display: DisplayInfo) -> Bool {
        guard isAvailable, display.isBuiltin else { return false }
        if let canFn, !canFn(display.id) { return false }
        // Definitive proof: a successful read.
        return read(display) != nil
    }

    public func read(_ display: DisplayInfo) -> Double? {
        guard let getFn else { return nil }
        var value: Float = 0
        guard getFn(display.id, &value) == 0 else { return nil }
        guard value.isFinite, value >= 0, value <= 1.0001 else { return nil }
        return Double(value).clampedBrightness
    }

    @discardableResult
    public func write(_ display: DisplayInfo, value: Double) -> Bool {
        guard let setFn else { return false }
        let target = Float(value.clampedBrightness)
        guard setFn(display.id, target) == 0 else { return false }
        // Keeps the on-screen HUD and System Settings slider in sync.
        notifyFn?(display.id, Double(target))
        return true
    }
}
