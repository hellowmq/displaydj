import Testing

@testable import DisplayDJCore

@Test("Apple display registry port names require an exact numeric suffix")
func appleRegistryPortIndexParsing() {
  #expect(
    IOKitDDCServiceInventory.portIndex(in: "dispext0", prefix: "dispext") == 0
  )
  #expect(
    IOKitDDCServiceInventory.portIndex(in: "DCPEXT12", prefix: "dcpext") == 12
  )
  #expect(
    IOKitDDCServiceInventory.portIndex(
      in: "dispext0:dcpav-service-epic:0",
      prefix: "dispext"
    ) == nil
  )
  #expect(
    IOKitDDCServiceInventory.portIndex(
      in: "DCPEXT1Endpoint11",
      prefix: "dcpext"
    ) == nil
  )
  #expect(
    IOKitDDCServiceInventory.portIndex(in: "dispext", prefix: "dispext") == nil
  )
  #expect(
    IOKitDDCServiceInventory.portIndex(in: "dispext-1", prefix: "dispext") == nil
  )
}

@Test("Legacy M1 external DCP alias requires exact port-zero endpoint evidence")
func legacyM1ExternalPortParsing() {
  #expect(IOKitDDCServiceInventory.externalEndpointPortIndex(in: "dispext0:dcpav-service-epic:0") == 0)
  #expect(IOKitDDCServiceInventory.externalEndpointPortIndex(in: "dispext1:dcpav-service-epic:0") == 1)
  #expect(IOKitDDCServiceInventory.externalEndpointPortIndex(in: "dispext:dcpav-service-epic:0") == nil)
  #expect(IOKitDDCServiceInventory.externalEndpointPortIndex(in: "dispext0:dcpav-service-epic:0:extra") == nil)
  #expect(IOKitDDCServiceInventory.externalEndpointPortIndex(in: "dispext0:dcpav-service-epic:1") == nil)
  #expect(IOKitDDCServiceInventory.legacyExternalPortIndex(in: "dcpext", prefix: "dcpext", endpointPort: 0, externalLocation: true, completeFramebufferIdentity: true) == 0)
  #expect(IOKitDDCServiceInventory.legacyExternalPortIndex(in: "DCPEXT", prefix: "dcpext", endpointPort: 0, externalLocation: true, completeFramebufferIdentity: true) == 0)
  #expect(IOKitDDCServiceInventory.legacyExternalPortIndex(in: "dcpext", prefix: "dcpext", endpointPort: nil, externalLocation: true, completeFramebufferIdentity: true) == nil)
  #expect(IOKitDDCServiceInventory.legacyExternalPortIndex(in: "dcpext", prefix: "dcpext", endpointPort: 1, externalLocation: true, completeFramebufferIdentity: true) == nil)
  #expect(IOKitDDCServiceInventory.legacyExternalPortIndex(in: "dcpext", prefix: "dcpext", endpointPort: 0, externalLocation: false, completeFramebufferIdentity: true) == nil)
  #expect(IOKitDDCServiceInventory.legacyExternalPortIndex(in: "dcpext", prefix: "dcpext", endpointPort: 0, externalLocation: true, completeFramebufferIdentity: false) == nil)
  #expect(IOKitDDCServiceInventory.legacyExternalPortIndex(in: "dispext", prefix: "dispext", endpointPort: 0, externalLocation: true, completeFramebufferIdentity: true) == nil)
  #expect(IOKitDDCServiceInventory.legacyExternalPortIndex(in: "unknown", prefix: "unknown", endpointPort: 0, externalLocation: true, completeFramebufferIdentity: true) == nil)
  #expect(IOKitDDCServiceInventory.legacyExternalPortIndex(in: "dcpext1Endpoint11", prefix: "dcpext", endpointPort: 0, externalLocation: true, completeFramebufferIdentity: true) == nil)
}
