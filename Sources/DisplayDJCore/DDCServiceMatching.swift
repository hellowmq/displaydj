protocol DDCServiceMatching: Sendable {
  func prepared(
    for displays: [DisplayDescriptor]
  ) async -> any DDCServiceMatching

  func association(
    for display: DisplayDescriptor
  ) async throws -> DDCServiceAssociation
}

extension DDCServiceMatching {
  func prepared(
    for displays: [DisplayDescriptor]
  ) async -> any DDCServiceMatching {
    self
  }
}

struct DDCServiceIdentity: Equatable, Sendable {
  let registryEntryID: UInt64
  let serviceClass: String
  let matchBasis: DDCServiceMatchBasis
}

enum DDCServiceMatchBasis: String, Equatable, Sendable {
  case hardwareTuple = "hardware-tuple"
}

enum DDCServiceAssociation: Equatable, Sendable {
  case matched(DDCServiceIdentity)
  case notFound(reason: String)
  case unresolved(reason: String)
  case ambiguous(candidateCount: Int, reason: String)
}

struct DDCServiceCandidate: Equatable, Hashable, Sendable {
  let registryEntryID: UInt64
  let serviceClass: String
  let vendorID: UInt32?
  let productID: UInt32?
  let serialNumber: UInt32?
}

enum DDCServiceMatchingError: Error, Equatable, Sendable {
  case registryRootUnavailable
  case registryEnumerationFailed(operation: String, status: Int32)
  case registryReadFailed(operation: String, status: Int32)
  case registryTopologyChanged
  case unexpectedInventoryFailure(description: String)
  case unsupportedBackend(BackendKind)

  var message: String {
    switch self {
    case .registryRootUnavailable:
      "The I/O Registry root is unavailable for passive DDC service matching."
    case .registryEnumerationFailed:
      "The I/O Registry could not be enumerated for passive DDC service matching."
    case .registryReadFailed:
      "A DDC service identity could not be read from the I/O Registry."
    case .registryTopologyChanged:
      "The I/O Registry display topology changed during passive DDC service matching."
    case .unexpectedInventoryFailure:
      "The passive DDC service inventory failed unexpectedly."
    case .unsupportedBackend:
      "The selected backend has no passive DDC service inventory."
    }
  }

  var details: [String: String] {
    switch self {
    case .registryRootUnavailable:
      ["reason": "registry-root-unavailable"]
    case .registryEnumerationFailed(let operation, let status):
      [
        "operation": operation,
        "reason": "registry-enumeration-failed",
        "status": String(status),
      ]
    case .registryReadFailed(let operation, let status):
      [
        "operation": operation,
        "reason": "registry-read-failed",
        "status": String(status),
      ]
    case .registryTopologyChanged:
      ["reason": "registry-topology-changed"]
    case .unexpectedInventoryFailure(let description):
      [
        "reason": "unexpected-inventory-failure",
        "underlyingError": description,
      ]
    case .unsupportedBackend(let backend):
      [
        "backend": backend.rawValue,
        "reason": "unsupported-service-inventory",
      ]
    }
  }
}

protocol DDCServiceInventoryReading: Sendable {
  func candidates() throws -> [DDCServiceCandidate]
}

actor DDCServiceMatcher: DDCServiceMatching {
  private static let maximumSnapshotAttempts = 3

  private let inventory: any DDCServiceInventoryReading
  private let isTranslatedX86Process: Bool
  private var preparation = DDCServicePreparation.unprepared

  init(
    inventory: any DDCServiceInventoryReading,
    isTranslatedX86Process: Bool = false
  ) {
    self.inventory = inventory
    self.isTranslatedX86Process = isTranslatedX86Process
  }

  static func current(for kind: BackendKind) -> DDCServiceMatcher {
    DDCServiceMatcher(
      inventory: IOKitDDCServiceInventory(kind: kind),
      isTranslatedX86Process: DDCProcessEnvironment.isTranslatedX86Process
    )
  }

  func prepared(
    for displays: [DisplayDescriptor]
  ) async -> any DDCServiceMatching {
    let scopedMatcher = DDCServiceMatcher(
      inventory: inventory,
      isTranslatedX86Process: isTranslatedX86Process
    )
    await scopedMatcher.prepareInPlace(for: displays)
    return scopedMatcher
  }

  private func prepareInPlace(for displays: [DisplayDescriptor]) async {
    let competingDisplays = displays.filter(Self.canCompeteForServiceIdentity)
    let conflictedIdentities = Self.conflictedIdentities(in: competingDisplays)
    let hasAssociationTarget = displays.contains(where: Self.isEligibleForServiceMatching)

    guard !isTranslatedX86Process, hasAssociationTarget else {
      preparation = .ready(candidates: [], conflictedIdentities: conflictedIdentities)
      return
    }

    do {
      preparation = .ready(
        candidates: try stableCandidates(),
        conflictedIdentities: conflictedIdentities
      )
    } catch let error as DDCServiceMatchingError {
      preparation = .failed(error)
    } catch {
      preparation = .failed(
        .unexpectedInventoryFailure(description: String(describing: error))
      )
    }
  }

  func association(
    for display: DisplayDescriptor
  ) async throws -> DDCServiceAssociation {
    if let preflightResult = preflightAssociation(for: display) {
      return preflightResult
    }

    guard let displayIdentity = DDCHardwareIdentity(display: display) else {
      return .unresolved(
        reason: "The display lacks a nonzero vendor, product, and serial identity."
      )
    }

    switch preparation {
    case .unprepared:
      return .unresolved(
        reason: "DDC service matching was not prepared with the complete display topology."
      )
    case .failed(let error):
      throw error
    case .ready(let candidates, let conflictedIdentities):
      guard !conflictedIdentities.contains(displayIdentity) else {
        return .unresolved(
          reason: "Another online display may share this validated hardware identity."
        )
      }
      return DDCServiceCandidateMatcher.association(
        for: display,
        candidates: candidates
      )
    }
  }

  private func preflightAssociation(
    for display: DisplayDescriptor
  ) -> DDCServiceAssociation? {
    if isTranslatedX86Process {
      return .unresolved(
        reason: "An x86_64 process translated by Rosetta is not treated as an Intel DDC host."
      )
    }
    if display.isBuiltIn {
      return .notFound(
        reason: "Built-in displays are excluded from the external DDC service inventory."
      )
    }
    if display.isVirtual == true {
      return .notFound(
        reason: "Virtual displays are excluded from the physical DDC service inventory."
      )
    }
    if display.isVirtual == nil {
      return .unresolved(
        reason: "The display could not be classified as physical or virtual."
      )
    }
    if display.isMirrored {
      return .unresolved(
        reason: [
          "Mirrored displays are not associated per runtime ID",
          "because a service may be shared.",
        ].joined(separator: " ")
      )
    }
    return nil
  }

  private func stableCandidates() throws -> [DDCServiceCandidate] {
    for _ in 0..<Self.maximumSnapshotAttempts {
      let before = Self.canonicalized(try inventory.candidates())
      let after = Self.canonicalized(try inventory.candidates())
      if before == after {
        return after
      }
    }
    throw DDCServiceMatchingError.registryTopologyChanged
  }

  private static func canonicalized(
    _ candidates: [DDCServiceCandidate]
  ) -> [DDCServiceCandidate] {
    Dictionary(grouping: candidates, by: \.registryEntryID)
      .map { registryEntryID, group in
        let uniqueCandidates = Set(group)
        guard uniqueCandidates.count == 1, let candidate = uniqueCandidates.first else {
          return DDCServiceCandidate(
            registryEntryID: registryEntryID,
            serviceClass: "UnresolvedIOService",
            vendorID: nil,
            productID: nil,
            serialNumber: nil
          )
        }
        return candidate
      }
      .sorted { $0.registryEntryID < $1.registryEntryID }
  }

  private static func conflictedIdentities(
    in displays: [DisplayDescriptor]
  ) -> Set<DDCHardwareIdentity> {
    let completeIdentities = displays.compactMap(DDCHardwareIdentity.init(display:))
    return Set(
      completeIdentities.filter { identity in
        displays.count { display in
          identity.mayBeRepresented(
            vendorID: display.vendorID,
            productID: display.productID,
            serialNumber: display.serialNumber
          )
        } > 1
      }
    )
  }

  private static func canCompeteForServiceIdentity(
    _ display: DisplayDescriptor
  ) -> Bool {
    display.isVirtual != true
  }

  private static func isEligibleForServiceMatching(
    _ display: DisplayDescriptor
  ) -> Bool {
    !display.isBuiltIn && display.isVirtual == false && !display.isMirrored
  }
}

private enum DDCServicePreparation {
  case unprepared
  case ready(
    candidates: [DDCServiceCandidate],
    conflictedIdentities: Set<DDCHardwareIdentity>
  )
  case failed(DDCServiceMatchingError)
}
