import DisplayDJCore
import Foundation
import Testing

@testable import DisplayDJCLI

@Test("Brightness Set JSON freezes verified write and identity schema")
func brightnessSetJSONSchema() throws {
  let result = try makeBrightnessSetResult()
  let data = try SetBrightnessOutput.jsonData(for: result)
  let root = try #require(
    JSONSerialization.jsonObject(with: data) as? [String: Any]
  )
  let display = try #require(root["display"] as? [String: Any])

  expectBrightnessSetRoot(root)
  expectBrightnessSetDisplay(display)
}

@Test("Brightness Set text is the applied external 0...100 value")
func brightnessSetText() throws {
  let result = try makeBrightnessSetResult()

  #expect(SetBrightnessOutput.text(for: result) == "37.5")
}

private func expectBrightnessSetRoot(_ root: [String: Any]) {
  #expect(
    Set(root.keys)
      == [
        "appliedValue",
        "backend",
        "control",
        "display",
        "exitCode",
        "ok",
        "readOnly",
        "requestedValue",
        "schemaVersion",
        "unit",
        "wasVerified",
      ]
  )
  #expect(root["schemaVersion"] as? Int == 1)
  #expect(root["ok"] as? Bool == true)
  #expect(root["exitCode"] as? Int == 0)
  #expect(root["readOnly"] as? Bool == false)
  #expect(root["backend"] as? String == "apple-silicon-ddc")
  #expect(root["control"] as? String == "brightness")
  #expect(root["requestedValue"] as? Double == 40.0)
  #expect(root["appliedValue"] as? Double == 37.5)
  #expect(root["wasVerified"] as? Bool == true)
  #expect(root["unit"] as? String == "percent")
}

private func expectBrightnessSetDisplay(_ display: [String: Any]) {
  #expect(
    Set(display.keys)
      == [
        "isBuiltIn",
        "isMirrored",
        "isVirtual",
        "mirrorSourceRuntimeID",
        "name",
        "productID",
        "runtimeID",
        "serialNumber",
        "stableID",
        "vendorID",
        "virtualDetectionSource",
      ]
  )
  #expect(display["runtimeID"] as? Int == 42)
  #expect(display["stableID"] as? String == "uuid:75490c7d-7258-479e-9bce-da9c8c60ac84")
  #expect(display["name"] as? String == "HP D27k")
  #expect(display["vendorID"] as? Int == 8_944)
  #expect(display["productID"] as? Int == 62_327)
  #expect(display["serialNumber"] as? Int == 51_580)
  #expect(display["isBuiltIn"] as? Bool == false)
  #expect(display["isVirtual"] as? Bool == false)
  #expect(display["virtualDetectionSource"] as? String == "core-display")
  #expect(display["isMirrored"] as? Bool == false)
  #expect(display["mirrorSourceRuntimeID"] is NSNull)
}

private func makeBrightnessSetResult() throws -> ControlWriteResult {
  ControlWriteResult(
    display: DisplayDescriptor(
      runtimeID: 42,
      stableID: "uuid:75490c7d-7258-479e-9bce-da9c8c60ac84",
      name: "HP D27k",
      vendorID: 8_944,
      productID: 62_327,
      serialNumber: 51_580,
      isBuiltIn: false,
      isVirtual: false,
      virtualDetectionSource: .coreDisplay,
      isMirrored: false
    ),
    backend: .appleSiliconDDC,
    control: .brightness,
    requestedValue: try DisplayControlValue(percent: 40),
    appliedValue: try DisplayControlValue(percent: 37.5),
    wasVerified: true
  )
}
