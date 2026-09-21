import Foundation
import CoreGraphics

public struct DisplayModeInfo: Codable, Equatable, Sendable, Identifiable {
    public let id: Int32
    public let width: Int
    public let height: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// Zero means the system did not report a fixed refresh rate.
    public let refreshRate: Double
    public let usable: Bool
    public let hiDPI: Bool

    public init(id: Int32, width: Int, height: Int, pixelWidth: Int, pixelHeight: Int,
                refreshRate: Double, usable: Bool = true) {
        self.id = id; self.width = width; self.height = height; self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight; self.refreshRate = refreshRate; self.usable = usable
        self.hiDPI = pixelWidth > width || pixelHeight > height
    }

    init(_ mode: CGDisplayMode) {
        self.init(id: mode.ioDisplayModeID, width: mode.width, height: mode.height,
                  pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                  refreshRate: mode.refreshRate, usable: mode.isUsableForDesktopGUI())
    }
}

public struct DisplayModeReport: Codable, Sendable {
    public let displayUUID: String
    public let slug: String
    public let current: DisplayModeInfo
    public let modes: [DisplayModeInfo]
}

public struct DisplayModeChange: Codable, Sendable {
    public let displayUUID: String
    public let previous: DisplayModeInfo
    public let requested: DisplayModeInfo
    public let observed: DisplayModeInfo?
    public let dryRun: Bool
    public let verified: Bool
}

public final class DisplayModeService {
    public static let shared = DisplayModeService()
    private let inventory: () -> [DisplayInfo]
    private let readModes: (UInt32) throws -> (DisplayModeInfo, [DisplayModeInfo])
    private let applyMode: (UInt32, Int32) throws -> Void

    public convenience init() {
        self.init(inventory: { DisplayRegistry.shared.displays(forceRefresh: true) }, read: { id in
            guard let current = CGDisplayCopyDisplayMode(id),
                  let modes = CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode] else {
                throw VibeError(.unsupportedOperation, "WindowServer did not report display modes")
            }
            return (DisplayModeInfo(current), modes.map(DisplayModeInfo.init))
        }, apply: { id, modeID in
            guard let modes = CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary) as? [CGDisplayMode],
                  let mode = modes.first(where: { $0.ioDisplayModeID == modeID }) else {
                throw VibeError(.displayNotFound, "display mode disappeared; list modes again")
            }
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let config else {
                throw VibeError(.backendFailure, "cannot begin display configuration")
            }
            let staged = CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
            guard staged == .success else {
                CGCancelDisplayConfiguration(config)
                throw VibeError(.backendFailure, "cannot configure display mode (\(staged.rawValue))")
            }
            let completed = CGCompleteDisplayConfiguration(config, .forSession)
            guard completed == .success else {
                throw VibeError(.backendFailure, "cannot complete display configuration (\(completed.rawValue))")
            }
            DisplayRegistry.shared.invalidate()
            BrightnessService.shared.invalidate()
        })
    }

    init(inventory: @escaping () -> [DisplayInfo],
         read: @escaping (UInt32) throws -> (DisplayModeInfo, [DisplayModeInfo]),
         apply: @escaping (UInt32, Int32) throws -> Void) {
        self.inventory = inventory; readModes = read; applyMode = apply
    }

    public func list(_ selector: DisplaySelector) throws -> [DisplayModeReport] {
        let targets = try selector.resolve(in: inventory())
        guard !targets.isEmpty else { throw VibeError(.displayNotFound, "no matching display") }
        return try targets.map { display in
            let (current, modes) = try readModes(display.id)
            return DisplayModeReport(displayUUID: display.uuid, slug: display.slug, current: current,
                                     modes: modes.sorted { $0.id < $1.id })
        }
    }

    public func set(_ modeID: Int32, selector: DisplaySelector, dryRun: Bool = false) throws -> DisplayModeChange {
        let initial = inventory()
        let targets = try selector.resolve(in: initial)
        guard targets.count == 1, let display = targets.first, UUID(uuidString: display.uuid) != nil else {
            throw VibeError(.invalidArgument, "mode changes require exactly one display with a stable UUID")
        }
        let (previous, modes) = try readModes(display.id)
        guard let requested = modes.first(where: { $0.id == modeID }), requested.usable else {
            throw VibeError(.invalidArgument, "mode \(modeID) is not an available desktop mode for \(display.slug)",
                            hint: "list modes again; mode IDs are only valid in the current display session")
        }
        if dryRun {
            return DisplayModeChange(displayUUID: display.uuid, previous: previous, requested: requested,
                                     observed: nil, dryRun: true, verified: false)
        }
        guard inventory() == initial else { throw VibeError(.sessionConflict, "display topology changed before mode application") }
        do {
            try applyMode(display.id, modeID)
            guard inventory().contains(where: { $0.id == display.id && $0.uuid == display.uuid }) else {
                throw VibeError(.sessionConflict, "display identity changed after mode application")
            }
            let observed = try readModes(display.id).0
            guard observed == requested else { throw VibeError(.backendFailure, "display mode readback did not match the request") }
            return DisplayModeChange(displayUUID: display.uuid, previous: previous, requested: requested,
                                     observed: observed, dryRun: false, verified: true)
        } catch {
            // Restore only if the runtime ID still belongs to the same display.
            var recovery = "not attempted: display identity changed"
            if inventory().contains(where: { $0.id == display.id && $0.uuid == display.uuid }) {
                do {
                    try applyMode(display.id, previous.id)
                    recovery = try readModes(display.id).0 == previous ? "verified" : "readback mismatch"
                } catch { recovery = "failed: \(error)" }
            }
            throw VibeError(.backendFailure, "mode change failed: \(error); restoration \(recovery)")
        }
    }
}
