// Portions of this read-only service inventory are adapted from MonitorControl.
// Copyright © MonitorControl contributors. Licensed under the MIT License;
// see LICENSES/DisplayDJ.txt.

import CoreGraphics
import Darwin
import Foundation
import IOKit

struct IOKitDDCServiceInventory: DDCServiceInventoryReading {
  private typealias IdentitiesByPort = [UInt32: RegistryHardwareIdentity]

  let kind: BackendKind

  func candidates() throws -> [DDCServiceCandidate] {
    switch kind {
    case .appleSiliconDDC:
      try appleSiliconCandidates()
    case .intelDDC:
      try intelCandidates()
    case .nativeBrightness, .gamma, .shadeHelper, .mock:
      throw DDCServiceMatchingError.unsupportedBackend(kind)
    }
  }

  private func appleSiliconCandidates() throws -> [DDCServiceCandidate] {
    let identitiesByPort = try appleFramebufferIdentitiesByPort()
    return try withMatchingServices(className: "DCPAVServiceProxy") { proxy in
      let location = registryStringProperty("Location", for: proxy)
      guard location == "External" || location == nil else {
        return []
      }

      let port = try ancestorPortIndex(
        for: proxy,
        prefix: "dcpext",
        externalLocation: location == "External",
        completePortZeroIdentity: identitiesByPort[0]?.isComplete == true
      )
      let identity = port.flatMap { identitiesByPort[$0] }
      let proxyCandidate = try candidate(
        for: proxy,
        serviceClass: "DCPAVServiceProxy",
        identity: location == "External" ? identity ?? RegistryHardwareIdentity() : .init()
      )
      return [proxyCandidate]
    }
  }

  private func appleFramebufferIdentitiesByPort() throws -> IdentitiesByPort {
    var identities: [UInt32: [RegistryHardwareIdentity]] = [:]
    for framebufferClass in ["AppleCLCD2", "IOMobileFramebufferShim"] {
      _ = try withMatchingServices(className: framebufferClass) { framebuffer in
        if let port = try ancestorPortIndex(for: framebuffer, prefix: "dispext") {
          identities[port, default: []].append(
            registryHardwareIdentity(for: framebuffer)
          )
        }
        return []
      }
    }

    return identities.compactMapValues { values in
      let uniqueValues = Set(values)
      guard uniqueValues.count == 1 else {
        return nil
      }
      return uniqueValues.first
    }
  }

  private func intelCandidates() throws -> [DDCServiceCandidate] {
    try withMatchingServices(className: "IOFramebuffer") { framebuffer in
      let framebufferCandidate = try candidate(
        for: framebuffer,
        serviceClass: "IOFramebuffer",
        identity: intelRegistryIdentity(for: framebuffer)
      )
      return [framebufferCandidate]
    }
  }

  private func withMatchingServices(
    className: String,
    body: (io_service_t) throws -> [DDCServiceCandidate]
  ) throws -> [DDCServiceCandidate] {
    guard let matching = IOServiceMatching(className) else {
      throw DDCServiceMatchingError.registryEnumerationFailed(
        operation: "IOServiceMatching",
        status: kIOReturnNoMemory
      )
    }

    var iterator: io_iterator_t = IO_OBJECT_NULL
    let status = IOServiceGetMatchingServices(
      kIOMainPortDefault,
      matching,
      &iterator
    )
    guard status == KERN_SUCCESS else {
      throw DDCServiceMatchingError.registryEnumerationFailed(
        operation: "IOServiceGetMatchingServices",
        status: status
      )
    }
    defer { IOObjectRelease(iterator) }

    var candidates: [DDCServiceCandidate] = []
    while true {
      let service = IOIteratorNext(iterator)
      guard service != IO_OBJECT_NULL else {
        break
      }
      defer { IOObjectRelease(service) }
      candidates.append(contentsOf: try body(service))
    }
    return candidates
  }

  private func ancestorPortIndex(
    for entry: io_registry_entry_t,
    prefix: String,
    externalLocation: Bool = false,
    completePortZeroIdentity: Bool = false
  ) throws -> UInt32? {
    var current = entry
    var ownsCurrent = false
    var endpointPort: UInt32?
    defer {
      if ownsCurrent {
        IOObjectRelease(current)
      }
    }

    for _ in 0..<64 {
      let name = try registryName(for: current)
      if prefix == "dcpext", let port = Self.externalEndpointPortIndex(in: name) {
        // Keep the endpoint evidence nearest to the proxy.
        if endpointPort == nil { endpointPort = port }
      }
      if let port = Self.portIndex(in: name, prefix: prefix) {
        return port
      }
      // Original M1 registries name the first external DCP "dcpext".
      // Accept this alias only when its proxy's endpoint independently says port 0.
      if Self.legacyExternalPortIndex(in: name, prefix: prefix, endpointPort: endpointPort,
        externalLocation: externalLocation,
        completeFramebufferIdentity: completePortZeroIdentity
      ) != nil {
        return 0
      }

      var parent: io_registry_entry_t = IO_OBJECT_NULL
      let status = IORegistryEntryGetParentEntry(
        current,
        kIOServicePlane,
        &parent
      )
      guard status == KERN_SUCCESS, parent != IO_OBJECT_NULL else {
        return nil
      }
      if ownsCurrent {
        IOObjectRelease(current)
      }
      current = parent
      ownsCurrent = true
    }
    return nil
  }

  static func portIndex(
    in registryName: String,
    prefix: String
  ) -> UInt32? {
    let normalizedName = registryName.lowercased()
    guard normalizedName.hasPrefix(prefix) else {
      return nil
    }
    let suffix = normalizedName.dropFirst(prefix.count)
    guard !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else {
      return nil
    }
    return UInt32(suffix)
  }

  static func externalEndpointPortIndex(in registryName: String) -> UInt32? {
    let suffix = ":dcpav-service-epic:0"
    let name = registryName.lowercased()
    guard name.hasSuffix(suffix) else { return nil }
    return portIndex(in: String(name.dropLast(suffix.count)), prefix: "dispext")
  }

  static func legacyExternalPortIndex(
    in registryName: String,
    prefix: String,
    endpointPort: UInt32?,
    externalLocation: Bool = false,
    completeFramebufferIdentity: Bool = false
  ) -> UInt32? {
    guard externalLocation, completeFramebufferIdentity,
      prefix == "dcpext", registryName.lowercased() == "dcpext", endpointPort == 0 else {
      return nil
    }
    return 0
  }

  private func candidate(
    for entry: io_registry_entry_t,
    serviceClass: String,
    identity: RegistryHardwareIdentity
  ) throws -> DDCServiceCandidate {
    var registryEntryID: UInt64 = 0
    let status = IORegistryEntryGetRegistryEntryID(entry, &registryEntryID)
    guard status == KERN_SUCCESS else {
      throw DDCServiceMatchingError.registryReadFailed(
        operation: "IORegistryEntryGetRegistryEntryID",
        status: status
      )
    }

    return DDCServiceCandidate(
      registryEntryID: registryEntryID,
      serviceClass: serviceClass,
      vendorID: identity.vendorID,
      productID: identity.productID,
      serialNumber: identity.serialNumber
    )
  }

  private func intelRegistryIdentity(
    for entry: io_registry_entry_t
  ) -> RegistryHardwareIdentity {
    guard
      let unmanagedInfo = IODisplayCreateInfoDictionary(
        entry,
        IOOptionBits(kIODisplayOnlyPreferredName)
      )
    else {
      return RegistryHardwareIdentity()
    }
    let info = unmanagedInfo.takeRetainedValue() as NSDictionary

    return RegistryHardwareIdentity(
      vendorID: uint32(info[kDisplayVendorID]),
      productID: uint32(info[kDisplayProductID]),
      serialNumber: uint32(info[kDisplaySerialNumber])
    )
  }

  private func registryHardwareIdentity(
    for entry: io_registry_entry_t
  ) -> RegistryHardwareIdentity {
    guard
      let displayAttributes = registryProperty("DisplayAttributes", for: entry) as? NSDictionary,
      let productAttributes = displayAttributes["ProductAttributes"] as? NSDictionary
    else {
      return RegistryHardwareIdentity()
    }

    return RegistryHardwareIdentity(
      vendorID: uint32(productAttributes["LegacyManufacturerID"]),
      productID: uint32(productAttributes["ProductID"]),
      serialNumber: uint32(productAttributes["SerialNumber"])
    )
  }

  private func registryName(
    for entry: io_registry_entry_t
  ) throws -> String {
    let capacity = MemoryLayout<io_name_t>.size
    let name = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
    defer { name.deallocate() }

    let status = IORegistryEntryGetName(entry, name)
    guard status == KERN_SUCCESS else {
      throw DDCServiceMatchingError.registryReadFailed(
        operation: "IORegistryEntryGetName",
        status: status
      )
    }
    return String(cString: name)
  }

  private func registryStringProperty(
    _ key: String,
    for entry: io_registry_entry_t
  ) -> String? {
    registryProperty(key, for: entry) as? String
  }

  private func registryProperty(
    _ key: String,
    for entry: io_registry_entry_t
  ) -> Any? {
    IORegistryEntryCreateCFProperty(
      entry,
      key as CFString,
      kCFAllocatorDefault,
      IOOptionBits(0)
    )?.takeRetainedValue()
  }

  private func uint32(_ value: Any?) -> UInt32? {
    guard let number = value as? NSNumber else {
      return nil
    }
    let signedValue = number.int64Value
    guard signedValue >= 0, signedValue <= Int64(UInt32.max) else {
      return nil
    }
    return UInt32(signedValue)
  }
}

private struct RegistryHardwareIdentity: Equatable, Hashable {
  var isComplete: Bool {
    [vendorID, productID, serialNumber].allSatisfy { value in
      guard let value else { return false }
      return value != 0 && value != UInt32.max
    }
  }

  let vendorID: UInt32?
  let productID: UInt32?
  let serialNumber: UInt32?

  init(
    vendorID: UInt32? = nil,
    productID: UInt32? = nil,
    serialNumber: UInt32? = nil
  ) {
    self.vendorID = vendorID
    self.productID = productID
    self.serialNumber = serialNumber
  }
}

enum DDCProcessEnvironment {
  static var isTranslatedX86Process: Bool {
    #if arch(x86_64)
      var translated: Int32 = 0
      var size = MemoryLayout<Int32>.size
      let status = sysctlbyname(
        "sysctl.proc_translated",
        &translated,
        &size,
        nil,
        0
      )
      return status == 0 && translated == 1
    #else
      false
    #endif
  }
}
