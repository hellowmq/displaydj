import Foundation
import DisplayDJCore

public typealias MonitorControl = DDCContinuousControl

public struct MonitorControlResult: Codable, Equatable, Sendable {
    public let displayUUID: String
    public let slug: String
    public let control: MonitorControl
    public let value: Double?
    public let requested: Double?
    public let ok: Bool
    public let verified: Bool
    public let dryRun: Bool
    public let error: String?
}

/// Each control is probed independently. Brightness support never implies
/// contrast or audio support; failed reads are visible as individual results.
public final class MonitorControlService {
    public static let shared = MonitorControlService()
    private let inventory: () -> [DisplayInfo]
    private let reader: (MonitorControl, String) throws -> Double
    private let writer: (MonitorControl, String, Double, Bool) throws -> Double

    public convenience init() {
        self.init(inventory: { DisplayRegistry.shared.displays(forceRefresh: true) }, read: { control, uuid in
            try SynchronousTask.run { try await AppleSiliconDDCControl().read(control, fromStableID: uuid).value.normalized }
        }, write: { control, uuid, value, relative in
            let result = try SynchronousTask.run {
                try await AppleSiliconDDCControl().write(control, normalized: value, relative: relative, toStableID: uuid)
            }
            guard result.wasVerified else { throw VibeError(.backendFailure, "DDC write was not verified") }
            return result.appliedValue.normalized
        })
    }

    init(inventory: @escaping () -> [DisplayInfo], read: @escaping (MonitorControl, String) throws -> Double,
         write: @escaping (MonitorControl, String, Double, Bool) throws -> Double) {
        self.inventory = inventory; reader = read; writer = write
    }

    public func read(_ control: MonitorControl, selector: DisplaySelector) throws -> [MonitorControlResult] {
        try targets(selector).map { display in
            do {
                let value = try reader(control, identity(display))
                try Self.validate(value)
                return result(display, control, value: value)
            } catch { return result(display, control, error: String(describing: error)) }
        }
    }

    public func set(_ control: MonitorControl, target: String, selector: DisplaySelector,
                    dryRun: Bool = false) throws -> [MonitorControlResult] {
        let parsed = try Self.parseTarget(target)
        return try targets(selector).map { display in
            do {
                let uuid = try identity(display)
                if dryRun {
                    let current = try reader(control, uuid)
                    try Self.validate(current)
                    let requested = parsed.relative ? (current + parsed.value).clampedBrightness : parsed.value
                    return result(display, control, value: current, requested: requested, dryRun: true)
                }
                let observed = try writer(control, uuid, parsed.value, parsed.relative)
                try Self.validate(observed)
                return result(display, control, value: observed, requested: parsed.relative ? nil : parsed.value, verified: true)
            } catch { return result(display, control, dryRun: dryRun, error: String(describing: error)) }
        }
    }

    public static func parseTarget(_ raw: String) throws -> (value: Double, relative: Bool) {
        switch try BrightnessTarget.parse(raw) {
        case .absolute(let value): return (value, false)
        case .relative(let value) where (-1...1).contains(value): return (value, true)
        default: throw VibeError(.invalidArgument, "control value must be 0…1, 0…100%, or a delta within ±100%; restore is brightness-only")
        }
    }

    private func targets(_ selector: DisplaySelector) throws -> [DisplayInfo] {
        let displays = try selector.resolve(in: inventory())
        guard !displays.isEmpty else { throw VibeError(.displayNotFound, "no matching display") }
        return displays
    }

    private func identity(_ display: DisplayInfo) throws -> String {
        guard let selector = DDCBackend.selector(for: display) else {
            throw VibeError(.unsupportedOperation, "DDC contrast/volume require an external display with a stable UUID")
        }
        return selector
    }

    private static func validate(_ value: Double) throws {
        guard value.isFinite, (0...1).contains(value) else { throw VibeError(.backendFailure, "invalid DDC readback") }
    }

    private func result(_ d: DisplayInfo, _ control: MonitorControl, value: Double? = nil,
                        requested: Double? = nil, verified: Bool = false, dryRun: Bool = false,
                        error: String? = nil) -> MonitorControlResult {
        MonitorControlResult(displayUUID: d.uuid, slug: d.slug, control: control, value: value,
                             requested: requested, ok: error == nil, verified: verified, dryRun: dryRun, error: error)
    }
}
