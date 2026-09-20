import Foundation
import Testing

@testable import DisplayDJCore

@Test("Percentage values normalize and round-trip")
func percentageNormalization() throws {
  let value = try DisplayControlValue(percent: 37.5)

  #expect(value.normalized == 0.375)
  #expect(value.percent == 37.5)

  let normalized = try DisplayControlValue(normalized: 0.375)
  #expect(normalized == value)
}

@Test("Control values accept both boundaries")
func controlValueBoundaries() throws {
  #expect(try DisplayControlValue(percent: 0).normalized == 0)
  #expect(try DisplayControlValue(percent: 100).normalized == 1)
  #expect(try DisplayControlValue(normalized: 0).percent == 0)
  #expect(try DisplayControlValue(normalized: 1).percent == 100)
}

@Test("Control values reject non-finite and out-of-range inputs")
func invalidControlValues() {
  let invalidPercentages: [Double] = [-0.01, 100.01, .infinity, -.infinity, .nan]

  for invalidPercentage in invalidPercentages {
    #expect(throws: DisplayDJError.self) {
      try DisplayControlValue(percent: invalidPercentage)
    }
  }

  let invalidNormalizedValues: [Double] = [-0.01, 1.01, .infinity, -.infinity, .nan]

  for invalidNormalizedValue in invalidNormalizedValues {
    #expect(throws: DisplayDJError.self) {
      try DisplayControlValue(normalized: invalidNormalizedValue)
    }
  }
}

@Test("JSON exposes percentages rather than internal normalized values")
func percentageJSONRepresentation() throws {
  let value = try DisplayControlValue(percent: 37.5)
  let data = try JSONEncoder().encode(value)

  #expect(String(data: data, encoding: .utf8) == "37.5")
  #expect(try JSONDecoder().decode(DisplayControlValue.self, from: data) == value)
}

@Test("Structured error codes map to stable CLI exit codes")
func stableExitCodes() {
  #expect(DisplayDJErrorCode.invalidArguments.cliExitCode == .usage)
  #expect(DisplayDJErrorCode.invalidValue.cliExitCode == .usage)
  #expect(DisplayDJErrorCode.displayNotFound.cliExitCode == .displayNotFound)
  #expect(DisplayDJErrorCode.ambiguousDisplay.cliExitCode == .ambiguousDisplay)
  #expect(DisplayDJErrorCode.unsupported.cliExitCode == .unsupported)
  #expect(DisplayDJErrorCode.backendUnavailable.cliExitCode == .backendUnavailable)
  #expect(DisplayDJErrorCode.timeout.cliExitCode == .timeout)
  #expect(DisplayDJErrorCode.busy.cliExitCode == .busy)
  #expect(DisplayDJErrorCode.verificationFailed.cliExitCode == .operationFailed)
  #expect(DisplayDJErrorCode.internalFailure.cliExitCode == .internalFailure)
}

@Test("Backend write completes before returning a result")
func awaitedBackendWrite() async throws {
  let display = DisplayDescriptor(
    runtimeID: 42,
    stableID: "mock:42",
    name: "Mock Display",
    isBuiltIn: false,
    isVirtual: false,
    isMirrored: false
  )
  let value = try DisplayControlValue(percent: 55)
  let backend = DelayedFakeBackend()

  let result = try await backend.write(
    ControlWriteRequest(control: .brightness, value: value),
    to: display
  )

  #expect(await backend.completedWriteCount() == 1)
  #expect(result.appliedValue == value)
  #expect(result.wasVerified)
}

private actor DelayedFakeBackend: DisplayControlBackend {
  nonisolated let kind: BackendKind = .mock
  nonisolated let probedCapabilities: Set<DisplayCapability> = [.brightness]
  private var writeCount = 0

  func probeCapabilities(
    for display: DisplayDescriptor
  ) async throws -> [DisplayCapabilityProbeResult] {
    [DisplayCapabilityProbeResult(capability: .brightness, state: .supported)]
  }

  func read(
    _ control: DisplayControl,
    from display: DisplayDescriptor
  ) async throws -> ControlReadResult {
    ControlReadResult(
      display: display,
      backend: kind,
      control: control,
      value: try DisplayControlValue(percent: 50)
    )
  }

  func write(
    _ request: ControlWriteRequest,
    to display: DisplayDescriptor
  ) async throws -> ControlWriteResult {
    try await Task.sleep(for: .milliseconds(10))
    writeCount += 1

    return ControlWriteResult(
      display: display,
      backend: kind,
      control: request.control,
      requestedValue: request.value,
      appliedValue: request.value,
      wasVerified: request.verifyAfterWrite
    )
  }

  func completedWriteCount() -> Int {
    writeCount
  }
}
