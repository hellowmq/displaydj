import Foundation
import Testing

@testable import DisplayDJCore

@Test("A unique validated hardware tuple associates one runtime-only DDC service")
func uniqueDDCServiceAssociation() async throws {
  let matcher = DDCServiceMatcher(
    inventory: DDCStaticServiceInventory(
      items: [
        makeServiceCandidate(registryEntryID: 0x100),
        makeServiceCandidate(
          registryEntryID: 0x200,
          vendorID: 0x0610,
          productID: 0x4909,
          serialNumber: 777
        ),
      ]
    )
  )

  let display = makeServiceDisplay()
  let preparedMatcher = await matcher.prepared(for: [display])
  let association = try await preparedMatcher.association(for: display)

  #expect(
    association
      == .matched(
        DDCServiceIdentity(
          registryEntryID: 0x100,
          serviceClass: "DCPAVServiceProxy",
          matchBasis: .hardwareTuple
        )
      )
  )
}

@Test("Duplicate hardware tuples are ambiguous instead of selecting the first service")
func duplicateDDCServiceAssociationsAreAmbiguous() async throws {
  let matcher = DDCServiceMatcher(
    inventory: DDCStaticServiceInventory(
      items: [
        makeServiceCandidate(registryEntryID: 0x100),
        makeServiceCandidate(registryEntryID: 0x101),
      ]
    )
  )

  let display = makeServiceDisplay()
  let preparedMatcher = await matcher.prepared(for: [display])
  let association = try await preparedMatcher.association(for: display)

  guard case .ambiguous(let candidateCount, let reason) = association else {
    Issue.record("Expected an ambiguous DDC service association.")
    return
  }
  #expect(candidateCount == 2)
  #expect(reason.contains("same validated hardware identity"))
}

@Test("A display without a valid serial is not matched by name or runtime ID")
func weakDisplayIdentityDoesNotGuessAService() async throws {
  let matcher = DDCServiceMatcher(
    inventory: DDCStaticServiceInventory(
      items: [makeServiceCandidate(registryEntryID: 0x100)]
    )
  )
  let display = makeServiceDisplay(serialNumber: nil)

  let preparedMatcher = await matcher.prepared(for: [display])
  let association = try await preparedMatcher.association(for: display)

  guard case .unresolved(let reason) = association else {
    Issue.record("Expected an unresolved DDC service association.")
    return
  }
  #expect(reason.contains("lacks a nonzero vendor, product, and serial identity"))
}

@Test("Incomplete service metadata remains unknown instead of becoming false unavailable")
func incompleteServiceIdentityRemainsUnresolved() async throws {
  let incompleteCandidate = makeServiceCandidate(
    registryEntryID: 0x100,
    serialNumber: nil
  )
  let matcher = DDCServiceMatcher(
    inventory: DDCStaticServiceInventory(items: [incompleteCandidate])
  )

  let display = makeServiceDisplay()
  let preparedMatcher = await matcher.prepared(for: [display])
  let association = try await preparedMatcher.association(for: display)

  guard case .unresolved(let reason) = association else {
    Issue.record("Expected an unresolved DDC service association.")
    return
  }
  #expect(reason.contains("possibly matching DDC service"))
}

@Test("A possible incomplete match prevents a false unique association")
func incompleteCandidatePreventsFalseUniqueAssociation() async throws {
  let display = makeServiceDisplay()
  let matcher = DDCServiceMatcher(
    inventory: DDCStaticServiceInventory(
      items: [
        makeServiceCandidate(registryEntryID: 0x100),
        makeServiceCandidate(
          registryEntryID: 0x101,
          serialNumber: nil
        ),
      ]
    )
  )

  let preparedMatcher = await matcher.prepared(for: [display])
  let association = try await preparedMatcher.association(for: display)

  guard case .unresolved(let reason) = association else {
    Issue.record("Expected an incomplete possible match to remain unresolved.")
    return
  }
  #expect(reason.contains("possibly matching DDC service"))
}

@Test("Duplicate online hardware identities cannot claim one DDC service twice")
func duplicateDisplayIdentitiesRemainUnresolved() async throws {
  let first = makeServiceDisplay(runtimeID: 42)
  let second = makeServiceDisplay(runtimeID: 43)
  let matcher = DDCServiceMatcher(
    inventory: DDCStaticServiceInventory(
      items: [makeServiceCandidate(registryEntryID: 0x100)]
    )
  )

  let preparedMatcher = await matcher.prepared(for: [first, second])
  let firstAssociation = try await preparedMatcher.association(for: first)
  let secondAssociation = try await preparedMatcher.association(for: second)

  guard case .unresolved(let firstReason) = firstAssociation,
    case .unresolved(let secondReason) = secondAssociation
  else {
    Issue.record("Expected duplicate display identities to remain unresolved.")
    return
  }
  #expect(firstReason.contains("Another online display may share"))
  #expect(secondReason.contains("Another online display may share"))
}

@Test("A partial online display identity blocks another display's unique match")
func partialDisplayIdentityPreventsFalseUniqueAssociation() async throws {
  let complete = makeServiceDisplay(runtimeID: 42)
  let partial = makeServiceDisplay(
    runtimeID: 43,
    serialNumber: nil,
    isVirtual: nil
  )
  let matcher = DDCServiceMatcher(
    inventory: DDCStaticServiceInventory(
      items: [makeServiceCandidate(registryEntryID: 0x100)]
    )
  )

  let preparedMatcher = await matcher.prepared(for: [complete, partial])
  let association = try await preparedMatcher.association(for: complete)

  guard case .unresolved(let reason) = association else {
    Issue.record("Expected a partial display identity to block a unique match.")
    return
  }
  #expect(reason.contains("Another online display may share"))
}

@Test("Mirror and built-in displays still compete for a service identity")
func nonTargetDisplaysPreventFalseUniqueAssociation() async throws {
  let target = makeServiceDisplay(runtimeID: 42)
  let mirrored = makeServiceDisplay(runtimeID: 43, isMirrored: true)
  let builtIn = makeServiceDisplay(runtimeID: 44, isBuiltIn: true)
  let matcher = DDCServiceMatcher(
    inventory: DDCStaticServiceInventory(
      items: [makeServiceCandidate(registryEntryID: 0x100)]
    )
  )

  let mirrorScope = await matcher.prepared(for: [target, mirrored])
  let builtInScope = await matcher.prepared(for: [target, builtIn])
  let mirrorAssociation = try await mirrorScope.association(for: target)
  let builtInAssociation = try await builtInScope.association(for: target)

  guard case .unresolved = mirrorAssociation,
    case .unresolved = builtInAssociation
  else {
    Issue.record("Expected non-target displays to block a unique association.")
    return
  }
}

@Test("An empty service inventory is unavailable rather than unsupported")
func emptyDDCServiceInventoryIsNotFound() async throws {
  let matcher = DDCServiceMatcher(
    inventory: DDCStaticServiceInventory(items: [])
  )

  let display = makeServiceDisplay()
  let preparedMatcher = await matcher.prepared(for: [display])
  let association = try await preparedMatcher.association(for: display)

  guard case .notFound(let reason) = association else {
    Issue.record("Expected no DDC service association.")
    return
  }
  #expect(reason.contains("No architecture-appropriate DDC services"))
}

@Test("Concurrent preparations return independent matcher scopes")
func concurrentPreparationsRemainIndependent() async throws {
  let complete = makeServiceDisplay(runtimeID: 42)
  let partial = makeServiceDisplay(runtimeID: 43, serialNumber: nil)
  let matcher = DDCServiceMatcher(
    inventory: DDCStaticServiceInventory(
      items: [makeServiceCandidate(registryEntryID: 0x100)]
    )
  )

  async let conflictedScope = matcher.prepared(for: [complete, partial])
  async let uniqueScope = matcher.prepared(for: [complete])
  let (conflicted, unique) = await (conflictedScope, uniqueScope)

  let conflictedAssociation = try await conflicted.association(for: complete)
  let uniqueAssociation = try await unique.association(for: complete)

  guard case .unresolved = conflictedAssociation else {
    Issue.record("Expected the conflicted scope to remain unresolved.")
    return
  }
  guard case .matched = uniqueAssociation else {
    Issue.record("Expected the independent unique scope to match.")
    return
  }
}

@Test("Changing I/O Registry snapshots fail instead of producing a mixed match")
func changingServiceInventoryFailsPreparation() async {
  let display = makeServiceDisplay()
  let matcher = DDCServiceMatcher(
    inventory: AlternatingDDCInventory(
      first: [makeServiceCandidate(registryEntryID: 0x100)],
      second: [makeServiceCandidate(registryEntryID: 0x200)]
    )
  )

  let preparedMatcher = await matcher.prepared(for: [display])

  do {
    _ = try await preparedMatcher.association(for: display)
    Issue.record("Expected an unstable registry-topology error.")
  } catch let error as DDCServiceMatchingError {
    #expect(error == .registryTopologyChanged)
  } catch {
    Issue.record("Unexpected error type: \(error)")
  }
}

@Test("Unsafe display states short-circuit before I/O Registry enumeration")
func unsafeDisplayStatesSkipServiceInventory() async throws {
  let matcher = DDCServiceMatcher(inventory: DDCFailingServiceInventory())
  let translatedMatcher = DDCServiceMatcher(
    inventory: DDCFailingServiceInventory(),
    isTranslatedX86Process: true
  )

  let builtIn = try await matcher.association(
    for: makeServiceDisplay(isBuiltIn: true)
  )
  let virtual = try await matcher.association(
    for: makeServiceDisplay(isVirtual: true)
  )
  let unknownVirtualState = try await matcher.association(
    for: makeServiceDisplay(isVirtual: nil)
  )
  let mirrored = try await matcher.association(
    for: makeServiceDisplay(isMirrored: true)
  )
  let translated = try await translatedMatcher.association(
    for: makeServiceDisplay()
  )

  guard case .notFound = builtIn else {
    Issue.record("Expected built-in DDC matching to be skipped.")
    return
  }
  guard case .notFound = virtual else {
    Issue.record("Expected virtual DDC matching to be skipped.")
    return
  }
  guard case .unresolved = unknownVirtualState else {
    Issue.record("Expected unknown virtual classification to remain unresolved.")
    return
  }
  guard case .unresolved = mirrored else {
    Issue.record("Expected mirrored DDC matching to remain unresolved.")
    return
  }
  guard case .unresolved(let translatedReason) = translated else {
    Issue.record("Expected translated x86_64 matching to remain unresolved.")
    return
  }
  #expect(translatedReason.contains("Rosetta"))
}

private final class AlternatingDDCInventory: DDCServiceInventoryReading, @unchecked Sendable {
  private let lock = NSLock()
  private let first: [DDCServiceCandidate]
  private let second: [DDCServiceCandidate]
  private var returnsFirst = true

  init(
    first: [DDCServiceCandidate],
    second: [DDCServiceCandidate]
  ) {
    self.first = first
    self.second = second
  }

  func candidates() throws -> [DDCServiceCandidate] {
    lock.lock()
    defer { lock.unlock() }
    defer { returnsFirst.toggle() }
    return returnsFirst ? first : second
  }
}

private struct DDCStaticServiceInventory: DDCServiceInventoryReading {
  let items: [DDCServiceCandidate]

  func candidates() throws -> [DDCServiceCandidate] {
    items
  }
}

private struct DDCFailingServiceInventory: DDCServiceInventoryReading {
  func candidates() throws -> [DDCServiceCandidate] {
    throw DDCServiceMatchingError.registryRootUnavailable
  }
}

private func makeServiceDisplay(
  runtimeID: UInt32 = 42,
  vendorID: UInt32? = 0x22F0,
  productID: UInt32? = 0x77F3,
  serialNumber: UInt32? = 51_580,
  isBuiltIn: Bool = false,
  isVirtual: Bool? = false,
  isMirrored: Bool = false
) -> DisplayDescriptor {
  DisplayDescriptor(
    runtimeID: runtimeID,
    stableID: "uuid:service-test-\(runtimeID)",
    name: "Name Must Not Be Used",
    vendorID: vendorID,
    productID: productID,
    serialNumber: serialNumber,
    isBuiltIn: isBuiltIn,
    isVirtual: isVirtual,
    isMirrored: isMirrored
  )
}

private func makeServiceCandidate(
  registryEntryID: UInt64,
  vendorID: UInt32? = 0x22F0,
  productID: UInt32? = 0x77F3,
  serialNumber: UInt32? = 51_580
) -> DDCServiceCandidate {
  DDCServiceCandidate(
    registryEntryID: registryEntryID,
    serviceClass: "DCPAVServiceProxy",
    vendorID: vendorID,
    productID: productID,
    serialNumber: serialNumber
  )
}
