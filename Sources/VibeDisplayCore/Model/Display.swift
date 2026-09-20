import Foundation
import CoreGraphics

/// How a brightness change is physically delivered to a panel.
public enum BrightnessTransport: String, Codable, CaseIterable, Sendable {
    /// Apple internal panel via the DisplayServices private framework.
    case displayServices = "display-services"
    /// External panel via DDC/CI VCP 0x10 over I2C.
    case ddc
    /// Gamma-table dimming (software only, no real backlight change).
    /// Requires a resident process — see `docs/ARCHITECTURE.md#gamma-caveat`.
    case gamma
    /// No transport available.
    case none

    public var isHardware: Bool { self == .displayServices || self == .ddc }
}

/// Result of probing what a display can actually do on this machine.
public struct DisplayCapability: Codable, Equatable, Sendable {
    public var canReadBrightness: Bool
    public var canWriteBrightness: Bool
    public var transports: [BrightnessTransport]
    public var preferred: BrightnessTransport
    public var notes: [String]

    public init(canReadBrightness: Bool = false,
                canWriteBrightness: Bool = false,
                transports: [BrightnessTransport] = [],
                preferred: BrightnessTransport = .none,
                notes: [String] = []) {
        self.canReadBrightness = canReadBrightness
        self.canWriteBrightness = canWriteBrightness
        self.transports = transports
        self.preferred = preferred
        self.notes = notes
    }

    public static let unsupported = DisplayCapability()
}

/// A physical display attached to this machine.
public struct DisplayInfo: Codable, Equatable, Identifiable, Sendable {
    /// CoreGraphics display id. Unstable across reconnects — never persist it.
    public let id: UInt32
    /// Stable across reboots/reconnects. Persist this.
    public let uuid: String
    /// Short kebab-case handle usable on the CLI, e.g. `builtin`, `dell-u2723qe`.
    public let slug: String
    public let name: String
    public let isBuiltin: Bool
    public let isMain: Bool
    public let vendorID: UInt32
    public let modelID: UInt32
    public let serialNumber: UInt32
    /// Index in the online display list. Stable within a single session only.
    public let index: Int
    public let width: Int
    public let height: Int
    public var capability: DisplayCapability

    public init(id: UInt32,
                uuid: String,
                slug: String,
                name: String,
                isBuiltin: Bool,
                isMain: Bool,
                vendorID: UInt32,
                modelID: UInt32,
                serialNumber: UInt32,
                index: Int,
                width: Int,
                height: Int,
                capability: DisplayCapability = .unsupported) {
        self.id = id
        self.uuid = uuid
        self.slug = slug
        self.name = name
        self.isBuiltin = isBuiltin
        self.isMain = isMain
        self.vendorID = vendorID
        self.modelID = modelID
        self.serialNumber = serialNumber
        self.index = index
        self.width = width
        self.height = height
        self.capability = capability
    }
}

/// A brightness reading, normalised to 0.0...1.0.
public struct BrightnessReading: Codable, Equatable, Sendable {
    public let displayUUID: String
    public let slug: String
    public let value: Double
    public let transport: BrightnessTransport
    public let readAt: Date

    public init(displayUUID: String, slug: String, value: Double, transport: BrightnessTransport, readAt: Date = Date()) {
        self.displayUUID = displayUUID
        self.slug = slug
        self.value = value
        self.transport = transport
        self.readAt = readAt
    }
}

/// Outcome of applying brightness to one display.
public struct BrightnessApplyResult: Codable, Equatable, Sendable {
    public let displayUUID: String
    public let slug: String
    /// Brightness read immediately before this write. `nil` when the display
    /// could not be read at all.
    public let previous: Double?
    public let requested: Double
    public let applied: Double?
    public let transport: BrightnessTransport
    public let ok: Bool
    /// True when this write was the first mutation of the display and the
    /// pre-existing value was recorded as the restore point (see docs/API.md).
    public let snapshotTaken: Bool
    public let error: String?

    public init(displayUUID: String,
                slug: String,
                previous: Double? = nil,
                requested: Double,
                applied: Double?,
                transport: BrightnessTransport,
                ok: Bool,
                snapshotTaken: Bool = false,
                error: String? = nil) {
        self.displayUUID = displayUUID
        self.slug = slug
        self.previous = previous
        self.requested = requested
        self.applied = applied
        self.transport = transport
        self.ok = ok
        self.snapshotTaken = snapshotTaken
        self.error = error
    }

    /// Decode tolerantly: payloads written before `previous`/`snapshotTaken`
    /// existed must still load, with the new fields defaulted.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayUUID = try c.decode(String.self, forKey: .displayUUID)
        slug = try c.decode(String.self, forKey: .slug)
        previous = try c.decodeIfPresent(Double.self, forKey: .previous)
        requested = try c.decode(Double.self, forKey: .requested)
        applied = try c.decodeIfPresent(Double.self, forKey: .applied)
        transport = try c.decode(BrightnessTransport.self, forKey: .transport)
        ok = try c.decode(Bool.self, forKey: .ok)
        snapshotTaken = try c.decodeIfPresent(Bool.self, forKey: .snapshotTaken) ?? false
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

public extension Double {
    /// Clamp to the canonical 0...1 brightness domain.
    var clampedBrightness: Double { Swift.min(1.0, Swift.max(0.0, self)) }
}
