import Foundation

public enum BackendKind: String, Codable, CaseIterable, Sendable {
  case intelDDC = "intel-ddc"
  case appleSiliconDDC = "apple-silicon-ddc"
  case nativeBrightness = "native-brightness"
  case gamma
  case shadeHelper = "shade-helper"
  case mock
}

public enum VirtualDisplayDetectionSource: String, Codable, CaseIterable, Sendable {
  case coreDisplay = "core-display"
  case builtIn = "built-in"
  case provided
  case unavailable
}

public enum DisplayCapability: String, Codable, CaseIterable, Sendable {
  case brightness
  case contrast
  case volume
  case mute
  case gamma
  case shade
}

/// Separates confirmed support from probe uncertainty or an unavailable probe.
public enum DisplayCapabilityState: String, Codable, CaseIterable, Sendable {
  case supported
  case unsupported
  case unknown
  case unavailable
}

/// One backend's explicit result for a capability it declares it can probe.
public struct DisplayCapabilityProbeResult: Codable, Equatable, Sendable {
  public let capability: DisplayCapability
  public let state: DisplayCapabilityState
  public let reason: String?

  public init(
    capability: DisplayCapability,
    state: DisplayCapabilityState,
    reason: String? = nil
  ) {
    self.capability = capability
    self.state = state
    self.reason = reason
  }
}

/// The normalized contribution from one backend to an aggregate assessment.
public struct DisplayCapabilitySource: Codable, Equatable, Sendable {
  public let backend: BackendKind
  public let state: DisplayCapabilityState
  public let reason: String?
  public let errorCode: DisplayDJErrorCode?

  public init(
    backend: BackendKind,
    state: DisplayCapabilityState,
    reason: String? = nil,
    errorCode: DisplayDJErrorCode? = nil
  ) {
    self.backend = backend
    self.state = state
    self.reason = reason
    self.errorCode = errorCode
  }
}

public struct DisplayCapabilityAssessment: Codable, Equatable, Sendable {
  public let capability: DisplayCapability
  public let state: DisplayCapabilityState
  public let sources: [DisplayCapabilitySource]

  public init(
    capability: DisplayCapability,
    state: DisplayCapabilityState,
    sources: [DisplayCapabilitySource]
  ) {
    self.capability = capability
    self.state = state
    self.sources = sources
  }
}

public struct DisplayCapabilitiesReport: Codable, Equatable, Sendable {
  public let display: DisplayDescriptor
  public let capabilities: [DisplayCapabilityAssessment]

  public init(
    display: DisplayDescriptor,
    capabilities: [DisplayCapabilityAssessment]
  ) {
    self.display = display
    self.capabilities = capabilities
  }
}

public enum DisplayControl: String, Codable, CaseIterable, Sendable {
  case brightness
  case contrast
  case volume
  case mute
  case gamma
  case shade
}

/// A snapshot of display identity and topology.
///
/// `runtimeID` is intentionally distinct from `stableID`: CoreGraphics runtime
/// identifiers may change after reconnecting or reconfiguring a display.
public struct DisplayDescriptor: Codable, Hashable, Sendable {
  public let runtimeID: UInt32
  public let stableID: String?
  public let name: String
  public let vendorID: UInt32?
  public let productID: UInt32?
  public let serialNumber: UInt32?
  public let isBuiltIn: Bool
  /// `nil` means the available system APIs could not classify the display.
  public let isVirtual: Bool?
  public let virtualDetectionSource: VirtualDisplayDetectionSource
  public let isMirrored: Bool
  public let mirrorSourceRuntimeID: UInt32?

  public init(
    runtimeID: UInt32,
    stableID: String? = nil,
    name: String,
    vendorID: UInt32? = nil,
    productID: UInt32? = nil,
    serialNumber: UInt32? = nil,
    isBuiltIn: Bool,
    isVirtual: Bool?,
    virtualDetectionSource: VirtualDisplayDetectionSource = .provided,
    isMirrored: Bool,
    mirrorSourceRuntimeID: UInt32? = nil
  ) {
    self.runtimeID = runtimeID
    self.stableID = stableID
    self.name = name
    self.vendorID = vendorID
    self.productID = productID
    self.serialNumber = serialNumber
    self.isBuiltIn = isBuiltIn
    self.isVirtual = isVirtual
    self.virtualDetectionSource = virtualDetectionSource
    self.isMirrored = isMirrored
    self.mirrorSourceRuntimeID = mirrorSourceRuntimeID
  }
}

public enum DisplaySelector: Hashable, Sendable {
  /// Valid only for the current online topology; IDs can change or be reused.
  case runtimeID(UInt32)
  case stableID(String)
  case all
  case builtIn
  case external
}

public struct ControlReadResult: Codable, Hashable, Sendable {
  public let display: DisplayDescriptor
  public let backend: BackendKind
  public let control: DisplayControl
  public let value: DisplayControlValue

  public init(
    display: DisplayDescriptor,
    backend: BackendKind,
    control: DisplayControl,
    value: DisplayControlValue
  ) {
    self.display = display
    self.backend = backend
    self.control = control
    self.value = value
  }
}

public struct ControlWriteRequest: Codable, Hashable, Sendable {
  public let control: DisplayControl
  public let value: DisplayControlValue
  public let verifyAfterWrite: Bool

  public init(
    control: DisplayControl,
    value: DisplayControlValue,
    verifyAfterWrite: Bool = true
  ) {
    self.control = control
    self.value = value
    self.verifyAfterWrite = verifyAfterWrite
  }
}

public struct ControlWriteResult: Codable, Hashable, Sendable {
  public let display: DisplayDescriptor
  public let backend: BackendKind
  public let control: DisplayControl
  public let requestedValue: DisplayControlValue
  public let appliedValue: DisplayControlValue
  public let wasVerified: Bool

  public init(
    display: DisplayDescriptor,
    backend: BackendKind,
    control: DisplayControl,
    requestedValue: DisplayControlValue,
    appliedValue: DisplayControlValue,
    wasVerified: Bool
  ) {
    self.display = display
    self.backend = backend
    self.control = control
    self.requestedValue = requestedValue
    self.appliedValue = appliedValue
    self.wasVerified = wasVerified
  }
}
