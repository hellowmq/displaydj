import DisplayDJCore
import Foundation
import Testing

@testable import DisplayDJCLI

@Test("Brightness Get JSON freezes identity, percent, and read-only schema")
func brightnessGetJSONSchema() throws {
  let result = try makeBrightnessGetResult()
  let data = try GetBrightnessOutput.jsonData(for: result)
  let root = try #require(
    JSONSerialization.jsonObject(with: data) as? [String: Any]
  )
  let display = try #require(root["display"] as? [String: Any])

  expectBrightnessRoot(root)
  expectBrightnessDisplay(display)
}

@Test("Brightness Get text is the external 0...100 value")
func brightnessGetText() throws {
  let result = try makeBrightnessGetResult()

  #expect(GetBrightnessOutput.text(for: result) == "37.5")
}

private func expectBrightnessRoot(_ root: [String: Any]) {
  #expect(
    Set(root.keys)
      == [
        "backend",
        "control",
        "display",
        "exitCode",
        "ok",
        "readOnly",
        "schemaVersion",
        "unit",
        "value",
      ]
  )
  #expect(root["schemaVersion"] as? Int == 1)
  #expect(root["ok"] as? Bool == true)
  #expect(root["exitCode"] as? Int == 0)
  #expect(root["readOnly"] as? Bool == true)
  #expect(root["backend"] as? String == "apple-silicon-ddc")
  #expect(root["control"] as? String == "brightness")
  #expect(root["value"] as? Double == 37.5)
  #expect(root["unit"] as? String == "percent")
}

private func expectBrightnessDisplay(_ display: [String: Any]) {
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

private func makeBrightnessGetResult() throws -> ControlReadResult {
  ControlReadResult(
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
    value: try DisplayControlValue(percent: 37.5)
  )
}
