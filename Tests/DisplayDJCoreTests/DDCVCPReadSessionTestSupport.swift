@testable import DisplayDJCore

enum ReadSessionMatcherOutcome: Sendable {
  case association(DDCServiceAssociation)
  case failure(DDCServiceMatchingError)
  case gatedAssociationIgnoringCancellation(TestGate, DDCServiceAssociation)
  case gatedFailureIgnoringCancellation(TestGate, DDCServiceMatchingError)
}

struct RootReadSessionMatcher: DDCServiceMatching {
  let outcome: ReadSessionMatcherOutcome
  let recorder: ReadSessionMatcherRecorder

  func prepared(
    for displays: [DisplayDescriptor]
  ) async -> any DDCServiceMatching {
    await recorder.recordPreparation(displays)
    return PreparedReadSessionMatcher(
      outcome: outcome,
      recorder: recorder
    )
  }

  func association(
    for display: DisplayDescriptor
  ) async throws -> DDCServiceAssociation {
    throw DDCServiceMatchingError.unexpectedInventoryFailure(
      description: "The unprepared test matcher was used."
    )
  }
}

struct PreparedReadSessionMatcher: DDCServiceMatching {
  let outcome: ReadSessionMatcherOutcome
  let recorder: ReadSessionMatcherRecorder

  func association(
    for display: DisplayDescriptor
  ) async throws -> DDCServiceAssociation {
    await recorder.recordAssociation(display)

    switch outcome {
    case .association(let association):
      return association
    case .failure(let error):
      throw error
    case .gatedAssociationIgnoringCancellation(let gate, let association):
      await gate.wait()
      return association
    case .gatedFailureIgnoringCancellation(let gate, let error):
      await gate.wait()
      throw error
    }
  }
}

struct ReadSessionMatcherSnapshot: Sendable {
  let preparedTopologies: [[DisplayDescriptor]]
  let associatedDisplays: [DisplayDescriptor]
}

actor ReadSessionMatcherRecorder {
  private struct AssociationWaiter {
    let expectedCount: Int
    let continuation: CheckedContinuation<Void, Never>
  }

  private var preparedTopologies: [[DisplayDescriptor]] = []
  private var associatedDisplays: [DisplayDescriptor] = []
  private var associationWaiters: [AssociationWaiter] = []

  func recordPreparation(_ displays: [DisplayDescriptor]) {
    preparedTopologies.append(displays)
  }

  func recordAssociation(_ display: DisplayDescriptor) {
    associatedDisplays.append(display)
    resumeSatisfiedAssociationWaiters()
  }

  func waitUntilAssociationCount(_ expectedCount: Int) async {
    guard associatedDisplays.count < expectedCount else {
      return
    }

    await withCheckedContinuation { continuation in
      associationWaiters.append(
        AssociationWaiter(
          expectedCount: expectedCount,
          continuation: continuation
        )
      )
    }
  }

  func snapshot() -> ReadSessionMatcherSnapshot {
    ReadSessionMatcherSnapshot(
      preparedTopologies: preparedTopologies,
      associatedDisplays: associatedDisplays
    )
  }

  private func resumeSatisfiedAssociationWaiters() {
    var waiting: [AssociationWaiter] = []
    for waiter in associationWaiters {
      if associatedDisplays.count >= waiter.expectedCount {
        waiter.continuation.resume()
      } else {
        waiting.append(waiter)
      }
    }
    associationWaiters = waiting
  }
}

struct ReadSessionAssociationFailureCase: Sendable {
  let association: DDCServiceAssociation
  let code: DisplayDJErrorCode
  let reason: String
  let candidateCount: String?

  init(
    association: DDCServiceAssociation,
    code: DisplayDJErrorCode,
    reason: String,
    candidateCount: String? = nil
  ) {
    self.association = association
    self.code = code
    self.reason = reason
    self.candidateCount = candidateCount
  }
}

func makeReadSessionDisplay(
  runtimeID: UInt32 = 42,
  stableID: String? = nil,
  serialNumber: UInt32 = 51_580
) -> DisplayDescriptor {
  DisplayDescriptor(
    runtimeID: runtimeID,
    stableID: stableID ?? "uuid:read-session-\(runtimeID)",
    name: "Read Session Test Display",
    vendorID: 0x22F0,
    productID: 0x77F3,
    serialNumber: serialNumber,
    isBuiltIn: false,
    isVirtual: false,
    isMirrored: false
  )
}

func makeReadSessionService(
  registryEntryID: UInt64 = 0xA100
) -> DDCServiceIdentity {
  DDCServiceIdentity(
    registryEntryID: registryEntryID,
    serviceClass: "DCPAVServiceProxy",
    matchBasis: .hardwareTuple
  )
}
