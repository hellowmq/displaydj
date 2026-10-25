import DisplayDJCore
import VibeDisplayCore

protocol LiteBrightnessAccess: Sendable {
  func read(stableID: String) async throws -> Int
  func write(percent: Int, stableID: String) async throws -> Int
}

/// Hardware-only adapter. Reuses Full's backlight backend, DDC transactions,
/// and manual-control arbitration without starting a CLI or background service.
@MainActor
final class LiteHardwareBrightnessAccess: LiteBrightnessAccess {
  var discovery: any DisplayDiscovering = CoreGraphicsDisplayDiscovery()
  var nativeBackend: any BrightnessBackend = DisplayServicesBackend()
  var coordinator: BrightnessCoordinator = .shared
  var readDDC: (String) async throws -> Double = { id in
    try await AppleSiliconDDCBrightnessReader().read(fromStableID: id).value.percent
  }
  var writeDDC: (Double, String) async throws -> Double = { percent, id in
    try await AppleSiliconDDCBrightnessWriter().write(percent: percent, toStableID: id).appliedValue.percent
  }

  func read(stableID: String) async throws -> Int {
    let display = try await resolve(stableID)
    if !display.isBuiltIn { return try Self.percent(await readDDC(stableID)) }
    let info = nativeInfo(display)
    guard nativeBackend.supports(info), let value = nativeBackend.read(info) else {
      throw LiteRefusal("无法读取这台屏幕的硬件亮度；未启用软件调光。")
    }
    return try Self.percent(value * 100)
  }

  func write(percent: Int, stableID: String) async throws -> Int {
    let target = try DisplayControlValue(percent: Double(percent))
    let lock = try await coordinator.acquire()
    defer { lock.release() }
    let display = try await resolve(stableID)
    if !display.isBuiltIn {
      try coordinator.takeManualControl(stableID: stableID)
      return try Self.percent(await writeDDC(Double(percent), stableID))
    }
    let info = nativeInfo(display)
    guard nativeBackend.supports(info) else { throw LiteRefusal("这台屏幕不支持原生背光调节。") }
    try coordinator.takeManualControl(stableID: stableID)
    guard nativeBackend.write(info, value: target.normalized) else {
      throw LiteRefusal("屏幕未接受亮度调节，请重新读取后重试。")
    }
    let current = try await resolve(stableID)
    guard current.runtimeID == display.runtimeID,
          let actual = nativeBackend.read(info), actual.isFinite,
          abs(actual - target.normalized) <= 0.01 else {
      throw LiteRefusal("未确认本次调节，请重新读取屏幕亮度。")
    }
    return try Self.percent(actual * 100)
  }

  private func resolve(_ id: String) async throws -> DisplayDescriptor {
    guard let canonical = LiteIdentity.stableID(id) else { throw LiteRefusal("无法确认屏幕身份。") }
    let displays = try await discovery.discoverDisplays()
    let matches = displays.filter { LiteIdentity.stableID($0.stableID) == canonical }
    guard matches.count == 1, let display = matches.first,
          !display.isMirrored, display.isVirtual == false else {
      throw LiteRefusal("屏幕已离线、正在镜像或身份不唯一，请刷新重试。")
    }
    return display
  }

  private static func percent(_ value: Double) throws -> Int {
    guard value.isFinite, (0...100).contains(value) else { throw LiteRefusal("屏幕未返回有效的亮度读数。") }
    return Int(value.rounded())
  }

  private func nativeInfo(_ display: DisplayDescriptor) -> DisplayInfo {
    DisplayInfo(id: display.runtimeID, uuid: display.stableID ?? "", slug: "builtin", name: display.name,
      isBuiltin: display.isBuiltIn, isMain: false, vendorID: display.vendorID ?? 0,
      modelID: display.productID ?? 0, serialNumber: display.serialNumber ?? 0,
      index: 0, width: 0, height: 0)
  }
}
