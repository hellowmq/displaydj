import DisplayDJCore
import Foundation
import Testing

@testable import DisplayDJCLI

@Test("Capabilities JSON uses schema v1 and explicit nulls")
func capabilitiesJSONSchema() throws {
  let report = makeCapabilitiesCLIReport()
  let data = try CapabilitiesOutput.jsonData(for: [report])
  let root = try #require(
    JSONSerialization.jsonObject(with: data) as? [String: Any]
  )
  let displays = try #require(root["displays"] as? [[String: Any]])
  let display = try #require(displays.first)
  let capabilities = try #require(display["capabilities"] as? [[String: Any]])
  let brightness = try #require(capabilities.first)
  let brightnessSources = try #require(brightness["sources"] as? [[String: Any]])
  let brightnessSource = try #require(brightnessSources.first)
  let contrast = try #require(capabilities.dropFirst().first)
  let contrastSources = try #require(contrast["sources"] as? [[String: Any]])
  let contrastSource = try #require(contrastSources.first)

  #expect(Set(root.keys) == ["displays", "readOnly", "schemaVersion"])
  #expect(
    Set(display.keys)
      == [
        "capabilities",
        "isBuiltIn",
        "isMirrored",
        "isVirtual",
        "name",
        "runtimeID",
        "stableID",
      ]
  )
  #expect(Set(brightness.keys) == ["capability", "sources", "state"])
  #expect(Set(brightnessSource.keys) == ["backend", "errorCode", "reason", "state"])
  #expect(Set(contrast.keys) == ["capability", "sources", "state"])
  #expect(Set(contrastSource.keys) == ["backend", "errorCode", "reason", "state"])
  #expect(root["schemaVersion"] as? Int == 1)
  #expect(root["readOnly"] as? Bool == true)
  #expect(display["runtimeID"] as? Int == 9)
  #expect(display["stableID"] is NSNull)
  #expect(display["isVirtual"] is NSNull)
  #expect(
    capabilities.map { $0["capability"] as? String }
      == DisplayCapability.allCases.map(\.rawValue)
  )
  #expect(brightness["state"] as? String == "supported")
  #expect(brightnessSource["backend"] as? String == "native-brightness")
  #expect(brightnessSource["reason"] is NSNull)
  #expect(brightnessSource["errorCode"] is NSNull)
  #expect(contrast["state"] as? String == "unknown")
  #expect(contrastSource["reason"] as? String == "Probe timed out.")
  #expect(contrastSource["errorCode"] as? String == "timeout")
}

@Test("Capabilities output preserves passive DDC evidence without claiming support")
func capabilitiesOutputPreservesPassiveDDCEvidence() throws {
  let source = DisplayCapabilitySource(
    backend: .appleSiliconDDC,
    state: .unknown,
    reason: "Entrypoints are loadable; no request was sent."
  )
  let assessment = DisplayCapabilityAssessment(
    capability: .brightness,
    state: .unknown,
    sources: [source]
  )
  let report = DisplayCapabilitiesReport(
    display: DisplayDescriptor(
      runtimeID: 17,
      stableID: "uuid:passive-ddc",
      name: "External Display",
      isBuiltIn: false,
      isVirtual: false,
      isMirrored: false
    ),
    capabilities: [assessment]
  )

  let data = try CapabilitiesOutput.jsonData(for: [report])
  let root = try #require(
    JSONSerialization.jsonObject(with: data) as? [String: Any]
  )
  let displays = try #require(root["displays"] as? [[String: Any]])
  let display = try #require(displays.first)
  let capabilities = try #require(display["capabilities"] as? [[String: Any]])
  let brightness = try #require(capabilities.first)
  let sources = try #require(brightness["sources"] as? [[String: Any]])
  let ddc = try #require(sources.first)

  #expect(brightness["state"] as? String == "unknown")
  #expect(ddc["backend"] as? String == "apple-silicon-ddc")
  #expect(ddc["state"] as? String == "unknown")
  #expect(ddc["reason"] as? String == "Entrypoints are loadable; no request was sent.")
  #expect(ddc["errorCode"] is NSNull)
  #expect(
    CapabilitiesOutput.text(for: [report]).contains(
      "brightness\tunknown\tapple-silicon-ddc=unknown:Entrypoints are loadable; no request was sent."
    )
  )
}

@Test("Capabilities text sanitizes untrusted fields and labels missing probes")
func capabilitiesTextOutput() {
  let display = DisplayDescriptor(
    runtimeID: 5,
    stableID: nil,
    name: "Unsafe\u{001B} Display\nName",
    isBuiltIn: false,
    isVirtual: nil,
    isMirrored: false
  )
  let source = DisplayCapabilitySource(
    backend: .intelDDC,
    state: .unknown,
    reason: "Timed\tout\u{0007}",
    errorCode: .timeout
  )
  let report = DisplayCapabilitiesReport(
    display: display,
    capabilities: [
      DisplayCapabilityAssessment(
        capability: .brightness,
        state: .unknown,
        sources: [source]
      ),
      DisplayCapabilityAssessment(
        capability: .shade,
        state: .unavailable,
        sources: []
      ),
    ]
  )

  let text = CapabilitiesOutput.text(for: [report])

  #expect(text.contains("runtime:5\tUnsafe  Display Name\truntime:5"))
  #expect(text.contains("brightness\tunknown\tintel-ddc=unknown:timeout:Timed out "))
  #expect(text.contains("shade\tunavailable\tno-probe-registered"))
  #expect(text.hasSuffix("read-only: no display control value was changed"))
  #expect(
    !text.unicodeScalars.contains {
      CharacterSet.controlCharacters.contains($0) && $0.value != 9 && $0.value != 10
    }
  )
}

private func makeCapabilitiesCLIReport() -> DisplayCapabilitiesReport {
  let display = DisplayDescriptor(
    runtimeID: 9,
    stableID: nil,
    name: "External Display",
    isBuiltIn: false,
    isVirtual: nil,
    isMirrored: false
  )
  let supportedSource = DisplayCapabilitySource(
    backend: .nativeBrightness,
    state: .supported
  )
  let unknownSource = DisplayCapabilitySource(
    backend: .intelDDC,
    state: .unknown,
    reason: "Probe timed out.",
    errorCode: .timeout
  )
  let capabilities = DisplayCapability.allCases.map { capability in
    switch capability {
    case .brightness:
      DisplayCapabilityAssessment(
        capability: capability,
        state: .supported,
        sources: [supportedSource]
      )
    case .contrast:
      DisplayCapabilityAssessment(
        capability: capability,
        state: .unknown,
        sources: [unknownSource]
      )
    case .volume, .mute, .gamma, .shade:
      DisplayCapabilityAssessment(
        capability: capability,
        state: .unavailable,
        sources: []
      )
    }
  }

  return DisplayCapabilitiesReport(display: display, capabilities: capabilities)
}
