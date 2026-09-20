@testable import DisplayDJCore

actor SequencedBrightnessDiscovery: DisplayDiscovering {
  private var snapshots: [[DisplayDescriptor]]
  private var callCount = 0

  init(snapshots: [[DisplayDescriptor]]) {
    self.snapshots = snapshots
  }

  func discoverDisplays() async throws -> [DisplayDescriptor] {
    callCount += 1
    guard snapshots.count > 1 else {
      return snapshots.first ?? []
    }
    return snapshots.removeFirst()
  }

  func snapshotCallCount() -> Int {
    callCount
  }
}

struct DisplayDJFailingBrightnessDiscovery: DisplayDiscovering {
  let error: DisplayDJError

  func discoverDisplays() async throws -> [DisplayDescriptor] {
    throw error
  }
}

struct UnexpectedFailingBrightnessDiscovery: DisplayDiscovering {
  func discoverDisplays() async throws -> [DisplayDescriptor] {
    throw BrightnessDiscoveryTestError.failed
  }
}

enum GatedBrightnessDiscoveryOutcome: Sendable {
  case success([DisplayDescriptor])
  case failure(DisplayDJError)
}

actor GatedBrightnessDiscovery: DisplayDiscovering {
  private let startedGate: TestGate
  private let releaseGate: TestGate
  private let outcome: GatedBrightnessDiscoveryOutcome

  init(
    startedGate: TestGate,
    releaseGate: TestGate,
    outcome: GatedBrightnessDiscoveryOutcome
  ) {
    self.startedGate = startedGate
    self.releaseGate = releaseGate
    self.outcome = outcome
  }

  func discoverDisplays() async throws -> [DisplayDescriptor] {
    await startedGate.open()
    await releaseGate.wait()

    switch outcome {
    case .success(let displays):
      return displays
    case .failure(let error):
      throw error
    }
  }
}

struct InvalidBrightnessCase: Sendable {
  let action: TransportAction
  let maximumValue: String
  let currentValue: String
  let valueType: String
}

enum BrightnessDiscoveryTestError: Error, Sendable {
  case failed
}

func invalidBrightnessCases() -> [InvalidBrightnessCase] {
  [
    InvalidBrightnessCase(
      action: .complete(.success(maximumValue: 0, currentValue: 0)),
      maximumValue: "0",
      currentValue: "0",
      valueType: "set-parameter"
    ),
    InvalidBrightnessCase(
      action: .complete(.success(maximumValue: 100, currentValue: 101)),
      maximumValue: "100",
      currentValue: "101",
      valueType: "set-parameter"
    ),
    InvalidBrightnessCase(
      action: .complete(
        .response(getFeatureReply(featureCode: 0x10, valueType: 0x01))
      ),
      maximumValue: "100",
      currentValue: "50",
      valueType: "momentary"
    ),
    InvalidBrightnessCase(
      action: .complete(
        .response(getFeatureReply(featureCode: 0x10, valueType: 0x7F))
      ),
      maximumValue: "100",
      currentValue: "50",
      valueType: "unknown-0x7F"
    ),
  ]
}

func makeBrightnessReader(
  discovery: any DisplayDiscovering,
  matcher: any DDCServiceMatching,
  transport: any DDCTransport
) -> DDCBrightnessReader {
  DDCBrightnessReader(
    discovery: discovery,
    backend: .appleSiliconDDC,
    serviceMatcher: matcher,
    executor: DDCVCPExecutor(
      transport: transport,
      policy: DDCExecutionPolicy(maximumAttempts: 1, attemptTimeout: nil)
    )
  )
}

func makeBrightnessWriter(
  discovery: any DisplayDiscovering,
  matcher: any DDCServiceMatching,
  transport: any DDCTransport,
  maximumAttempts: Int = 1,
  maximumSetAttempts: Int = 2
) -> DDCBrightnessWriter {
  DDCBrightnessWriter(
    discovery: discovery,
    backend: .appleSiliconDDC,
    serviceMatcher: matcher,
    executor: DDCVCPExecutor(
      transport: transport,
      policy: DDCExecutionPolicy(
        maximumAttempts: maximumAttempts,
        attemptTimeout: nil,
        maximumSetAttempts: maximumSetAttempts
      )
    )
  )
}
