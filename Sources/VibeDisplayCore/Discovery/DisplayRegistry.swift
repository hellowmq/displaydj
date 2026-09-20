import Foundation
import CoreGraphics
import AppKit

/// Enumerates the physical displays attached to this Mac and assigns each one a
/// stable identity (`uuid`) plus a human-friendly handle (`slug`).
///
/// Identity rules
/// --------------
/// * `CGDirectDisplayID` is treated as **ephemeral** — it changes when a cable
///   is replugged or the machine sleeps. It is never persisted.
/// * `uuid` comes from `CGDisplayCreateUUIDFromDisplayID` and is stable, so all
///   config files and agent sessions key off it.
/// * `slug` is derived from the product name and de-duplicated, so humans and
///   shell scripts get something typeable.
public final class DisplayRegistry {
    public static let shared = DisplayRegistry()

    private let lock = NSLock()
    private var cached: [DisplayInfo] = []
    private var cachedAt: Date = .distantPast
    /// The window server is slow to query; a short TTL keeps `list` snappy
    /// during a burst of agent calls without going stale across replugs.
    private let ttl: TimeInterval = 2.0

    public init() {}

    /// Online displays, cached for `ttl` seconds.
    public func displays(forceRefresh: Bool = false) -> [DisplayInfo] {
        lock.lock(); defer { lock.unlock() }
        if !forceRefresh, Date().timeIntervalSince(cachedAt) < ttl, !cached.isEmpty {
            return cached
        }
        cached = Self.enumerate()
        cachedAt = Date()
        return cached
    }

    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        cachedAt = .distantPast
        cached = []
    }

    /// Resolve a selector against a fresh snapshot.
    public func resolve(_ selector: DisplaySelector, forceRefresh: Bool = false) throws -> [DisplayInfo] {
        try selector.resolve(in: displays(forceRefresh: forceRefresh))
    }

    // MARK: - Enumeration

    private static func enumerate() -> [DisplayInfo] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }

        let mainID = CGMainDisplayID()
        let names = screenNames()

        var slugCounts: [String: Int] = [:]
        var result: [DisplayInfo] = []
        var index = 0

        for id in ids.prefix(Int(count)) {
            // Mirrored secondaries would double-apply brightness; skip them.
            if CGDisplayIsInMirrorSet(id) != 0, CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay {
                continue
            }

            let builtin = CGDisplayIsBuiltin(id) != 0
            let rawName = names[id] ?? (builtin ? "Built-in Display" : "Display \(id)")
            var slug = Self.slugify(rawName)
            if slug.isEmpty { slug = builtin ? "builtin" : "display-\(id)" }

            let seen = slugCounts[slug, default: 0]
            slugCounts[slug] = seen + 1
            if seen > 0 { slug = "\(slug)-\(seen + 1)" }

            let bounds = CGDisplayBounds(id)

            result.append(DisplayInfo(
                id: id,
                uuid: Self.stableUUID(for: id),
                slug: slug,
                name: rawName,
                isBuiltin: builtin,
                isMain: id == mainID,
                vendorID: CGDisplayVendorNumber(id),
                modelID: CGDisplayModelNumber(id),
                serialNumber: CGDisplaySerialNumber(id),
                index: index,
                width: Int(bounds.width),
                height: Int(bounds.height)
            ))
            index += 1
        }
        return result
    }

    /// `CGDisplayCreateUUIDFromDisplayID` is the canonical stable id. If the
    /// window server refuses (headless / no session), fall back to a synthetic
    /// but deterministic vendor-model-serial key.
    private static func stableUUID(for id: CGDirectDisplayID) -> String {
        if let ref = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
           let str = CFUUIDCreateString(nil, ref) as String? {
            return str
        }
        return String(format: "VMS-%08X-%08X-%08X",
                      CGDisplayVendorNumber(id),
                      CGDisplayModelNumber(id),
                      CGDisplaySerialNumber(id))
    }

    /// Product names come from AppKit. Accessing `NSScreen` from a non-GUI
    /// process is allowed inside a user session but can throw at the ObjC
    /// level in edge cases (ssh, launchd system domain), hence the guard.
    private static func screenNames() -> [CGDirectDisplayID: String] {
        var map: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { continue }
            let name = screen.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                map[CGDirectDisplayID(number.uint32Value)] = name
            }
        }
        return map
    }

    static func slugify(_ input: String) -> String {
        let lowered = input.lowercased()
        var out = ""
        var lastWasDash = false
        for ch in lowered {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasDash = false
            } else if !lastWasDash, !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }
}
