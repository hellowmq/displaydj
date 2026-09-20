import IOKit
import Testing

@testable import DisplayDJCore

extension AppleSiliconDDCTransportTests {
  @Test("executor sends one production Set packet then verifies with Get")
  func executorSetsOnceThenReadsBack() async throws {
    fakeIOAVState.reset(
      reply: getFeatureReply(
        featureCode: 0x10,
        maximumValue: 100,
        currentValue: 50
      )
    )
    let executor = DDCVCPExecutor(
      transport: try makeTransport(),
      policy: DDCExecutionPolicy(maximumAttempts: 2, attemptTimeout: nil)
    )

    let value = try await executor.setFeature(
      0x10,
      to: 50,
      on: makeAppleSiliconTarget()
    )

    #expect(value.currentValue == 50)
    let events = fakeIOAVState.eventsSnapshot()
    #expect(
      events.filter(isWriteEvent) == [
        .write(
          chipAddress: 0x37,
          dataAddress: 0x51,
          bytes: [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A]
        ),
        .write(
          chipAddress: 0x37,
          dataAddress: 0x51,
          bytes: [0x82, 0x01, 0x10, 0xFD]
        ),
        .write(
          chipAddress: 0x37,
          dataAddress: 0x51,
          bytes: [0x82, 0x01, 0x10, 0xFD]
        ),
      ]
    )
    #expect(events.count(where: isReadEvent) == 1)
    #expect(events.count(where: { $0 == .releaseIOAVService }) == 2)
    #expect(events.count(where: { $0 == .releaseRegistryService(0xBEEF) }) == 2)
  }

  @Test("typed fake symbols send one exact Set VCP packet without a reply read")
  func typedFakeSymbolsExerciseExactSetABI() async throws {
    fakeIOAVState.reset(reply: [])
    let response = try await makeTransport().exchange(
      DDCTransportRequest(
        logicalFrame: DDCVCPCodec.setFeatureRequest(
          featureCode: 0x10,
          value: 50
        ),
        replyCapacity: 0
      ),
      on: makeAppleSiliconTarget()
    )

    #expect(response.exactFrame.isEmpty)
    let events = fakeIOAVState.eventsSnapshot()
    #expect(
      Array(events.prefix(3)) == [
        .resolve(registryEntryID: 0xCAFE, serviceClass: "DCPAVServiceProxy"),
        .create(registryService: 0xBEEF),
        .write(
          chipAddress: 0x37,
          dataAddress: 0x51,
          bytes: [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A]
        ),
      ]
    )
    #expect(events.count(where: isWriteEvent) == 1)
    #expect(events.count(where: isReadEvent) == 0)
    #expect(events.count(where: { $0 == .releaseIOAVService }) == 1)
    #expect(events.count(where: { $0 == .releaseRegistryService(0xBEEF) }) == 1)
  }

  @Test("A repeated Set frame reaches the bus twice with no reply read")
  func repeatedSetFrameIsWrittenTwice() async throws {
    fakeIOAVState.reset(reply: [])
    let setPacket: [UInt8] = [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A]
    let response = try await makeTransport().exchange(
      DDCTransportRequest(
        logicalFrame: DDCVCPCodec.setFeatureRequest(
          featureCode: 0x10,
          value: 50
        ),
        replyCapacity: 0,
        writeFrameCount: 2
      ),
      on: makeAppleSiliconTarget()
    )

    #expect(response.exactFrame.isEmpty)
    let events = fakeIOAVState.eventsSnapshot()
    #expect(
      events.filter(isWriteEvent) == [
        .write(chipAddress: 0x37, dataAddress: 0x51, bytes: setPacket),
        .write(chipAddress: 0x37, dataAddress: 0x51, bytes: setPacket),
      ]
    )
    #expect(events.count(where: isReadEvent) == 0)
    #expect(events.count(where: { $0 == .releaseIOAVService }) == 1)
  }

  @Test("Set VCP rejects a nonzero reply capacity before native calls")
  func setVCPRejectsReplyCapacity() async throws {
    fakeIOAVState.reset(reply: [])
    let error = await capturedTransportError {
      try await makeTransport().exchange(
        DDCTransportRequest(
          logicalFrame: DDCVCPCodec.setFeatureRequest(
            featureCode: 0x10,
            value: 50
          ),
          replyCapacity: 1
        ),
        on: makeAppleSiliconTarget()
      )
    }

    #expect(
      error
        == .permanentFailure(
          operation: "validate-set-request",
          status: nil
        )
    )
    #expect(fakeIOAVState.eventsSnapshot().isEmpty)
  }

  @Test("Set VCP rejects a bad logical checksum before native calls")
  func setVCPRejectsBadChecksum() async throws {
    fakeIOAVState.reset(reply: [])
    let frame = {
      var frame = DDCVCPCodec.setFeatureRequest(featureCode: 0x10, value: 50)
      frame[frame.count - 1] ^= 0x01
      return frame
    }()

    let error = await capturedTransportError {
      try await makeTransport().exchange(
        DDCTransportRequest(logicalFrame: frame, replyCapacity: 0),
        on: makeAppleSiliconTarget()
      )
    }

    #expect(
      error
        == .permanentFailure(
          operation: "validate-set-request-checksum",
          status: nil
        )
    )
    #expect(fakeIOAVState.eventsSnapshot().isEmpty)
  }

  @Test("Set write failure is mapped after exactly one native call")
  func setWriteStatusIsMappedWithoutRetryOrRead() async throws {
    fakeIOAVState.reset(reply: [], writeStatus: kIOReturnBusy)
    let error = await capturedTransportError {
      try await makeTransport().exchange(
        DDCTransportRequest(
          logicalFrame: DDCVCPCodec.setFeatureRequest(
            featureCode: 0x10,
            value: 50
          ),
          replyCapacity: 0
        ),
        on: makeAppleSiliconTarget()
      )
    }

    #expect(error == .busy)
    let events = fakeIOAVState.eventsSnapshot()
    #expect(events.count(where: isWriteEvent) == 1)
    #expect(events.count(where: isReadEvent) == 0)
    #expect(events.count(where: { $0 == .releaseIOAVService }) == 1)
    #expect(events.count(where: { $0 == .releaseRegistryService(0xBEEF) }) == 1)
  }
}
