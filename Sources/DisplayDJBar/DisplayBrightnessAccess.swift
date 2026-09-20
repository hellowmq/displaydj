import DisplayDJCore
import VibeDisplayCore

/// Keeps the external DDC transaction intact while routing internal panels to
/// the same native backlight backend used by the CLI. No software dimming is
/// substituted when native hardware control is unavailable.
@MainActor
struct DisplayBrightnessAccess {
  var discovery: any DisplayDiscovering = CoreGraphicsDisplayDiscovery()
  var nativeBackend: any BrightnessBackend = DisplayServicesBackend()
  var readDDC: (String) async throws -> Double = { stableID in
    try await AppleSiliconDDCBrightnessReader().read(fromStableID: stableID).value.percent
  }
  var writeDDC: (Double, String) async throws -> Double = { percent, stableID in
    try await AppleSiliconDDCBrightnessWriter()
      .write(percent: percent, toStableID: stableID).appliedValue.percent
  }

  static func visibleDisplays(_ displays: [DisplayDescriptor]) -> [DisplayDescriptor] {
    displays.filter { !$0.isMirrored && $0.isVirtual != true }
  }

  func read(stableID: String) async throws -> Int {
    let display = try await resolve(stableID)
    guard display.isBuiltIn else {
      return Int(try await readDDC(stableID).rounded())
    }
    let info = nativeInfo(display)
    guard nativeBackend.supports(info) else { throw NativeBrightnessError.unavailable }
    guard let value = nativeBackend.read(info), value.isFinite, (0...1).contains(value) else {
      throw NativeBrightnessError.readFailed
    }
    return Int((value * 100).rounded())
  }

  func write(percent: Double, stableID: String) async throws -> Int {
    let target = try DisplayControlValue(percent: percent)
    let display = try await resolve(stableID)
    guard display.isBuiltIn else {
      return Int(try await writeDDC(percent, stableID).rounded())
    }
    let info = nativeInfo(display)
    guard nativeBackend.supports(info) else { throw NativeBrightnessError.unavailable }
    guard nativeBackend.write(info, value: target.normalized) else {
      throw NativeBrightnessError.writeRejected
    }
    // Read the actual native backlight value, never present the requested value
    // as a hardware confirmation. Native panels may quantize their brightness.
    guard let actual = nativeBackend.read(info), actual.isFinite, (0...1).contains(actual),
      abs(actual - target.normalized) <= 0.01
    else { throw NativeBrightnessError.unverified }
    return Int((actual * 100).rounded())
  }

  private func resolve(_ stableID: String) async throws -> DisplayDescriptor {
    try Task.checkCancellation()
    let topology = try await discovery.discoverDisplays()
    try Task.checkCancellation()
    let matches = try DisplaySelectorResolver().resolve(.stableID(stableID), among: topology)
    guard let display = matches.first else {
      throw DisplayDJError(code: .displayNotFound, message: "Display is no longer online.")
    }
    guard !display.isMirrored, display.isVirtual != true else {
      throw DisplayDJError(code: .unsupported, message: "Mirrored or virtual displays cannot be controlled here.")
    }
    return display
  }

  /// The native backend consumes only the fresh runtime ID and built-in flag.
  /// Presentation geometry is absent from discovery and is not used here.
  private func nativeInfo(_ display: DisplayDescriptor) -> DisplayInfo {
    DisplayInfo(
      id: display.runtimeID, uuid: display.stableID ?? "", slug: "builtin",
      name: display.name, isBuiltin: display.isBuiltIn, isMain: false,
      vendorID: display.vendorID ?? 0, modelID: display.productID ?? 0,
      serialNumber: display.serialNumber ?? 0, index: 0, width: 0, height: 0
    )
  }
}

enum NativeBrightnessError: Error {
  case unavailable
  case readFailed
  case writeRejected
  case unverified
}
