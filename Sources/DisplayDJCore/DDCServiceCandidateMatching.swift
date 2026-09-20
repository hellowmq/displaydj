enum DDCServiceCandidateMatcher {
  static func association(
    for display: DisplayDescriptor,
    candidates: [DDCServiceCandidate]
  ) -> DDCServiceAssociation {
    guard !candidates.isEmpty else {
      return .notFound(reason: "No architecture-appropriate DDC services were found.")
    }
    guard let displayIdentity = DDCHardwareIdentity(display: display) else {
      return .unresolved(
        reason: "The display lacks a nonzero vendor, product, and serial identity."
      )
    }

    let identified = candidates.compactMap { candidate -> IdentifiedCandidate? in
      guard let identity = DDCHardwareIdentity(candidate: candidate) else {
        return nil
      }
      return IdentifiedCandidate(candidate: candidate, identity: identity)
    }
    let matches = identified.filter { $0.identity == displayIdentity }
    let unresolvedCandidates = candidates.filter {
      DDCHardwareIdentity(candidate: $0) == nil
        && mayMatch($0, displayIdentity: displayIdentity)
    }

    if matches.count > 1 {
      return .ambiguous(
        candidateCount: matches.count,
        reason: "Multiple DDC services have the same validated hardware identity."
      )
    }
    if matches.count == 1, unresolvedCandidates.isEmpty {
      let candidate = matches[0].candidate
      return .matched(
        DDCServiceIdentity(
          registryEntryID: candidate.registryEntryID,
          serviceClass: candidate.serviceClass,
          matchBasis: .hardwareTuple
        )
      )
    }
    if !unresolvedCandidates.isEmpty {
      return .unresolved(
        reason: "At least one possibly matching DDC service lacks a complete hardware identity."
      )
    }
    return .notFound(
      reason: "No DDC service has the display's validated hardware identity."
    )
  }

  private static func mayMatch(
    _ candidate: DDCServiceCandidate,
    displayIdentity: DDCHardwareIdentity
  ) -> Bool {
    displayIdentity.mayBeRepresented(
      vendorID: candidate.vendorID,
      productID: candidate.productID,
      serialNumber: candidate.serialNumber
    )
  }
}

private struct IdentifiedCandidate {
  let candidate: DDCServiceCandidate
  let identity: DDCHardwareIdentity
}

struct DDCHardwareIdentity: Equatable, Hashable {
  let vendorID: UInt32
  let productID: UInt32
  let serialNumber: UInt32

  init?(display: DisplayDescriptor) {
    self.init(
      vendorID: display.vendorID,
      productID: display.productID,
      serialNumber: display.serialNumber
    )
  }

  init?(candidate: DDCServiceCandidate) {
    self.init(
      vendorID: candidate.vendorID,
      productID: candidate.productID,
      serialNumber: candidate.serialNumber
    )
  }

  func mayBeRepresented(
    vendorID: UInt32?,
    productID: UInt32?,
    serialNumber: UInt32?
  ) -> Bool {
    Self.component(vendorID, mayMatch: self.vendorID)
      && Self.component(productID, mayMatch: self.productID)
      && Self.component(serialNumber, mayMatch: self.serialNumber)
  }

  private static func component(
    _ candidateValue: UInt32?,
    mayMatch expectedValue: UInt32
  ) -> Bool {
    guard let candidateValue, candidateValue != 0, candidateValue != UInt32.max else {
      return true
    }
    return candidateValue == expectedValue
  }

  private init?(
    vendorID: UInt32?,
    productID: UInt32?,
    serialNumber: UInt32?
  ) {
    guard
      let vendorID,
      vendorID != 0,
      vendorID != UInt32.max,
      let productID,
      productID != 0,
      productID != UInt32.max,
      let serialNumber,
      serialNumber != 0,
      serialNumber != UInt32.max
    else {
      return nil
    }

    self.vendorID = vendorID
    self.productID = productID
    self.serialNumber = serialNumber
  }
}
