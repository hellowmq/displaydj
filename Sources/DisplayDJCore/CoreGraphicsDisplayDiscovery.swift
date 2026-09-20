import AppKit
import ColorSync
import CoreGraphics
import Darwin
import Foundation

/// Read-only discovery of the current online display topology.
///
/// CoreGraphics display IDs are exposed as runtime IDs only. Stable selectors
/// prefer the ColorSync display UUID and never fall back to a runtime ID or a
/// display name, both of which can change across reconnects.
public struct CoreGraphicsDisplayDiscovery: DisplayDiscovering {
  private let loadSnapshots: @MainActor @Sendable () throws -> [CoreGraphicsDisplaySnapshot]

  public init() {
    loadSnapshots = {
      try CoreGraphicsDisplaySnapshotLoader.load()
    }
  }

  init(
    loadSnapshots: @escaping @MainActor @Sendable () throws -> [CoreGraphicsDisplaySnapshot]
  ) {
    self.loadSnapshots = loadSnapshots
  }

  public func discoverDisplays() async throws -> [DisplayDescriptor] {
    let snapshots = try await loadSnapshots()

    return
      snapshots
      .map(\.descriptor)
      .sorted { lhs, rhs in
        if lhs.isBuiltIn != rhs.isBuiltIn {
          return lhs.isBuiltIn
        }

        switch (lhs.stableID, rhs.stableID) {
        case (let lhsID?, let rhsID?) where lhsID != rhsID:
          return lhsID < rhsID
        case (_?, nil):
          return true
        case (nil, _?):
          return false
        default:
          return lhs.runtimeID < rhs.runtimeID
        }
      }
  }
}

struct CoreGraphicsDisplaySnapshot: Sendable {
  let runtimeID: UInt32
  let uuidString: String?
  let name: String?
  let vendorID: UInt32?
  let productID: UInt32?
  let serialNumber: UInt32?
  let isBuiltIn: Bool
  let isVirtual: Bool?
  let virtualDetectionSource: VirtualDisplayDetectionSource
  let isMirrored: Bool
  let mirrorSourceRuntimeID: UInt32?

  var descriptor: DisplayDescriptor {
    DisplayDescriptor(
      runtimeID: runtimeID,
      stableID: DisplayStableIdentifier.make(
        uuidString: uuidString,
        vendorID: vendorID,
        productID: productID,
        serialNumber: serialNumber
      ),
      name: resolvedName,
      vendorID: vendorID,
      productID: productID,
      serialNumber: serialNumber,
      isBuiltIn: isBuiltIn,
      isVirtual: isVirtual,
      virtualDetectionSource: virtualDetectionSource,
      isMirrored: isMirrored,
      mirrorSourceRuntimeID: mirrorSourceRuntimeID
    )
  }

  private var resolvedName: String {
    if let name {
      let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmedName.isEmpty {
        return trimmedName
      }
    }

    if isBuiltIn {
      return "Built-in Display"
    }

    if let vendorID, let productID {
      return String(format: "Display %08x:%08x", vendorID, productID)
    }

    return "Display \(runtimeID)"
  }
}

enum DisplayStableIdentifier {
  static func make(
    uuidString: String?,
    vendorID: UInt32?,
    productID: UInt32?,
    serialNumber: UInt32?
  ) -> String? {
    if let uuidString, let uuid = UUID(uuidString: uuidString) {
      return "uuid:\(uuid.uuidString.lowercased())"
    }

    guard
      let vendorID,
      vendorID != 0,
      vendorID != UInt32.max,
      let productID,
      productID != 0,
      productID != UInt32.max,
      let serialNumber,
      serialNumber != 0
    else {
      return nil
    }

    return String(
      format: "hardware:%08x:%08x:%08x",
      vendorID,
      productID,
      serialNumber
    )
  }
}

private enum CoreGraphicsDisplaySnapshotLoader {
  private static let topologyReadAttempts = 3

  @MainActor
  static func load() throws -> [CoreGraphicsDisplaySnapshot] {
    for _ in 0..<topologyReadAttempts {
      let displayIDs = try onlineDisplayIDs()
      let snapshots = makeSnapshots(
        for: displayIDs,
        names: screenNamesByDisplayID()
      )
      let verificationIDs = try onlineDisplayIDs()

      if Set(displayIDs) == Set(verificationIDs) {
        return snapshots
      }
    }

    throw DisplayDJError(
      code: .transportFailure,
      message: "The online display topology changed while it was being inspected.",
      operation: .discover,
      details: [
        "reason": "topology-changed",
        "attempts": String(topologyReadAttempts),
      ]
    )
  }

  private static func makeSnapshots(
    for displayIDs: [CGDirectDisplayID],
    names: [CGDirectDisplayID: String]
  ) -> [CoreGraphicsDisplaySnapshot] {
    let onlineDisplayIDs = Set(displayIDs)

    return displayIDs.map { displayID in
      let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0
      let virtualDetection = virtualDetection(for: displayID, isBuiltIn: isBuiltIn)
      let isMirrored =
        CGDisplayIsInMirrorSet(displayID) != 0 || CGDisplayIsInHWMirrorSet(displayID) != 0
      let mirroredDisplayID = CGDisplayMirrorsDisplay(displayID)
      let mirrorSourceRuntimeID =
        isMirrored && mirroredDisplayID != kCGNullDirectDisplay
          && onlineDisplayIDs.contains(mirroredDisplayID)
        ? mirroredDisplayID
        : nil

      return CoreGraphicsDisplaySnapshot(
        runtimeID: displayID,
        uuidString: displayUUIDString(for: displayID),
        name: names[displayID],
        vendorID: normalizedHardwareID(CGDisplayVendorNumber(displayID)),
        productID: normalizedHardwareID(CGDisplayModelNumber(displayID)),
        serialNumber: normalizedSerialNumber(CGDisplaySerialNumber(displayID)),
        isBuiltIn: isBuiltIn,
        isVirtual: virtualDetection.isVirtual,
        virtualDetectionSource: virtualDetection.source,
        isMirrored: isMirrored,
        mirrorSourceRuntimeID: mirrorSourceRuntimeID
      )
    }
  }

  private static func onlineDisplayIDs() throws -> [CGDirectDisplayID] {
    var lastErrorCode: CGError.RawValue?

    for _ in 0..<topologyReadAttempts {
      var reportedCount: UInt32 = 0
      let countError = CGGetOnlineDisplayList(0, nil, &reportedCount)
      guard countError == .success else {
        lastErrorCode = countError.rawValue
        continue
      }

      guard reportedCount > 0 else {
        return []
      }

      // Leave a small buffer for a display arriving between the count and read calls.
      let capacity =
        reportedCount.addingReportingOverflow(4).overflow
        ? reportedCount
        : reportedCount + 4
      var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(capacity))
      var actualCount: UInt32 = 0
      let listError = displayIDs.withUnsafeMutableBufferPointer { buffer in
        CGGetOnlineDisplayList(capacity, buffer.baseAddress, &actualCount)
      }

      guard listError == .success else {
        lastErrorCode = listError.rawValue
        continue
      }

      guard actualCount <= capacity else {
        lastErrorCode = CGError.rangeCheck.rawValue
        continue
      }

      return Array(displayIDs.prefix(Int(actualCount))).filter { $0 != kCGNullDirectDisplay }
    }

    throw DisplayDJError(
      code: .transportFailure,
      message: "CoreGraphics could not provide a consistent online display snapshot.",
      operation: .discover,
      details: [
        "cgError": lastErrorCode.map(String.init) ?? "unknown",
        "attempts": String(topologyReadAttempts),
      ]
    )
  }

  @MainActor
  private static func screenNamesByDisplayID() -> [CGDirectDisplayID: String] {
    var result: [CGDirectDisplayID: String] = [:]

    for screen in NSScreen.screens {
      guard
        let screenNumber = screen.deviceDescription[
          NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber
      else {
        continue
      }

      result[screenNumber.uint32Value] = screen.localizedName
    }

    return result
  }

  private static func displayUUIDString(for displayID: CGDirectDisplayID) -> String? {
    guard
      let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(displayID),
      let uuidString = CFUUIDCreateString(nil, unmanagedUUID.takeRetainedValue())
    else {
      return nil
    }

    return uuidString as String
  }

  private static func normalizedHardwareID(_ value: UInt32) -> UInt32? {
    value == UInt32.max ? nil : value
  }

  private static func normalizedSerialNumber(_ value: UInt32) -> UInt32? {
    value == 0 || value == UInt32.max ? nil : value
  }

  private static func virtualDetection(
    for displayID: CGDirectDisplayID,
    isBuiltIn: Bool
  ) -> (isVirtual: Bool?, source: VirtualDisplayDetectionSource) {
    if let isVirtual = CoreDisplayVirtualDetector.isVirtual(displayID) {
      return (isVirtual, .coreDisplay)
    }

    if isBuiltIn {
      return (false, .builtIn)
    }

    return (nil, .unavailable)
  }
}

private enum CoreDisplayVirtualDetector {
  private typealias CreateInfoDictionary =
    @convention(c) (
      CGDirectDisplayID
    ) -> Unmanaged<CFDictionary>?

  static func isVirtual(_ displayID: CGDirectDisplayID) -> Bool? {
    guard
      let handle = dlopen(
        "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
        RTLD_LAZY | RTLD_LOCAL
      )
    else {
      return nil
    }
    defer { dlclose(handle) }

    guard let symbol = dlsym(handle, "CoreDisplay_DisplayCreateInfoDictionary") else {
      return nil
    }

    let createInfoDictionary = unsafeBitCast(symbol, to: CreateInfoDictionary.self)
    guard let info = createInfoDictionary(displayID)?.takeRetainedValue() else {
      return nil
    }

    let dictionary = info as NSDictionary
    let isVirtualDevice = dictionary["kCGDisplayIsVirtualDevice"] as? Bool
    let isAirPlay = dictionary["kCGDisplayIsAirPlay"] as? Bool

    guard isVirtualDevice != nil || isAirPlay != nil else {
      return nil
    }

    return (isVirtualDevice ?? false) || (isAirPlay ?? false)
  }
}
