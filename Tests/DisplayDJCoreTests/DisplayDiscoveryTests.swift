import Foundation
import Testing

@testable import DisplayDJCore

@Test("Stable display IDs prefer canonical UUIDs")
func stableDisplayIDPrefersUUID() {
  let stableID = DisplayStableIdentifier.make(
    uuidString: "A0B1C2D3-E4F5-4678-9123-456789ABCDEF",
    vendorID: 0x1234,
    productID: 0x5678,
    serialNumber: 99
  )

  #expect(stableID == "uuid:a0b1c2d3-e4f5-4678-9123-456789abcdef")
}

@Test("Hardware fallback requires a serial number and never uses a runtime ID")
func stableDisplayIDHardwareFallback() {
  #expect(
    DisplayStableIdentifier.make(
      uuidString: nil,
      vendorID: 0x1234,
      productID: 0x5678,
      serialNumber: 99
    ) == "hardware:00001234:00005678:00000063"
  )
  #expect(
    DisplayStableIdentifier.make(
      uuidString: nil,
      vendorID: 0x1234,
      productID: 0x5678,
      serialNumber: nil
    ) == nil
  )
}

@Test("CoreGraphics snapshots preserve topology flags and stable identity")
func coreGraphicsSnapshotMapping() async throws {
  let snapshots = [
    CoreGraphicsDisplaySnapshot(
      runtimeID: 99,
      uuidString: nil,
      name: " External Display ",
      vendorID: 0x1234,
      productID: 0x5678,
      serialNumber: 42,
      isBuiltIn: false,
      isVirtual: true,
      virtualDetectionSource: .coreDisplay,
      isMirrored: true,
      mirrorSourceRuntimeID: 7
    ),
    CoreGraphicsDisplaySnapshot(
      runtimeID: 7,
      uuidString: "00112233-4455-4677-8899-AABBCCDDEEFF",
      name: "Built-in Display",
      vendorID: 0x0610,
      productID: 1,
      serialNumber: nil,
      isBuiltIn: true,
      isVirtual: false,
      virtualDetectionSource: .builtIn,
      isMirrored: true,
      mirrorSourceRuntimeID: nil
    ),
  ]
  let discovery = CoreGraphicsDisplayDiscovery(loadSnapshots: { snapshots })

  let displays = try await discovery.discoverDisplays()

  #expect(displays.map(\.runtimeID) == [7, 99])
  #expect(displays[0].stableID == "uuid:00112233-4455-4677-8899-aabbccddeeff")
  #expect(displays[0].isBuiltIn)
  #expect(displays[0].isMirrored)
  #expect(displays[0].mirrorSourceRuntimeID == nil)
  #expect(displays[1].stableID == "hardware:00001234:00005678:0000002a")
  #expect(displays[1].name == "External Display")
  #expect(displays[1].isVirtual == true)
  #expect(displays[1].mirrorSourceRuntimeID == 7)
}

@Test("Stable selectors reject collisions instead of guessing between identical displays")
func stableSelectorRejectsCollisions() throws {
  let first = makeDisplay(runtimeID: 10, stableID: "hardware:00000001:00000002:00000003")
  let second = makeDisplay(runtimeID: 2, stableID: "hardware:00000001:00000002:00000003")

  do {
    _ = try DisplaySelectorResolver().resolve(
      .stableID("HARDWARE:00000001:00000002:00000003"),
      among: [first, second]
    )
    Issue.record("Expected an ambiguous-display error.")
  } catch let error as DisplayDJError {
    #expect(error.code == .ambiguousDisplay)
    #expect(error.details["runtimeIDs"] == "2,10")
  }
}

@Test("Selectors support runtime, built-in, and external display scopes")
func selectorScopes() throws {
  let builtIn = makeDisplay(runtimeID: 1, stableID: "uuid:built-in", isBuiltIn: true)
  let external = makeDisplay(runtimeID: 2, stableID: nil)
  let resolver = DisplaySelectorResolver()

  #expect(try resolver.resolve(.runtimeID(2), among: [builtIn, external]) == [external])
  #expect(try resolver.resolve(.builtIn, among: [builtIn, external]) == [builtIn])
  #expect(try resolver.resolve(.external, among: [builtIn, external]) == [external])
  #expect(try resolver.resolve(.all, among: [builtIn, external]) == [builtIn, external])
}

@Test("Unavailable virtual detection remains unknown")
func unavailableVirtualDetectionRemainsUnknown() async throws {
  let snapshot = CoreGraphicsDisplaySnapshot(
    runtimeID: 3,
    uuidString: nil,
    name: nil,
    vendorID: nil,
    productID: nil,
    serialNumber: nil,
    isBuiltIn: false,
    isVirtual: nil,
    virtualDetectionSource: .unavailable,
    isMirrored: false,
    mirrorSourceRuntimeID: nil
  )
  let discovery = CoreGraphicsDisplayDiscovery(loadSnapshots: { [snapshot] })

  let displays = try await discovery.discoverDisplays()
  let display = try #require(displays.first)

  #expect(display.isVirtual == nil)
  #expect(display.virtualDetectionSource == .unavailable)
  #expect(display.stableID == nil)
}

@Test("Stable selectors trim whitespace and reject control characters")
func stableSelectorInputBoundaries() throws {
  let display = makeDisplay(runtimeID: 4, stableID: "uuid:display")
  let resolver = DisplaySelectorResolver()

  #expect(
    try resolver.resolve(.stableID("  uuid:display\n"), among: [display]) == [display]
  )

  do {
    _ = try resolver.resolve(.stableID("uuid:\u{001B}display"), among: [display])
    Issue.record("Expected an invalid-selector error.")
  } catch let error as DisplayDJError {
    #expect(error.code == .invalidSelector)
  }
}

private func makeDisplay(
  runtimeID: UInt32,
  stableID: String?,
  isBuiltIn: Bool = false
) -> DisplayDescriptor {
  DisplayDescriptor(
    runtimeID: runtimeID,
    stableID: stableID,
    name: "Display \(runtimeID)",
    isBuiltIn: isBuiltIn,
    isVirtual: false,
    isMirrored: false
  )
}
