import CoreFoundation
import Foundation
import IOKit
import Testing

@testable import DisplayDJCore

@Suite("Apple Silicon DDC transport", .serialized)
struct AppleSiliconDDCTransportTests {
  @Test("typed fake symbols exercise the exact Get VCP IOAV ABI")
  func typedFakeSymbolsExerciseExactABI() async throws {
    let expectedReply = getFeatureReply(
      featureCode: 0x10,
      maximumValue: 300,
      currentValue: 120
    )
    fakeIOAVState.reset(reply: expectedReply)
    let transport = try makeTransport()
    let target = makeAppleSiliconTarget()

    let response = try await transport.exchange(
      DDCTransportRequest(
        logicalFrame: DDCVCPCodec.getFeatureRequest(featureCode: 0x10),
        replyCapacity: 16
      ),
      on: target
    )

    #expect(response.exactFrame == expectedReply)
    let events = fakeIOAVState.eventsSnapshot()
    #expect(
      Array(events.prefix(5)) == [
        .resolve(registryEntryID: 0xCAFE, serviceClass: "DCPAVServiceProxy"),
        .create(registryService: 0xBEEF),
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
        .read(chipAddress: 0x37, offset: 0, capacity: 16),
      ]
    )
    #expect(events.count(where: { $0 == .releaseIOAVService }) == 1)
    #expect(events.count(where: { $0 == .releaseRegistryService(0xBEEF) }) == 1)
  }

  @Test("executor parses a fake IOAV Get VCP response")
  func executorParsesFakeResponse() async throws {
    fakeIOAVState.reset(
      reply: getFeatureReply(
        featureCode: 0x10,
        maximumValue: 100,
        currentValue: 42
      )
    )
    let executor = DDCVCPExecutor(
      transport: try makeTransport(),
      policy: DDCExecutionPolicy(maximumAttempts: 1, attemptTimeout: nil)
    )

    let value = try await executor.getFeature(
      0x10,
      from: makeAppleSiliconTarget()
    )

    #expect(value.maximumValue == 100)
    #expect(value.currentValue == 42)
    #expect(fakeIOAVState.eventsSnapshot().count(where: isWriteEvent) == 2)
    #expect(fakeIOAVState.eventsSnapshot().count(where: isReadEvent) == 1)
  }

  @Test("null replies are trimmed without deleting protocol bytes")
  func nullReplyIsTrimmed() async throws {
    let nullReply: [UInt8] = [0x6E, 0x80, 0xBE]
    fakeIOAVState.reset(reply: nullReply)

    let response = try await makeTransport().exchange(
      DDCTransportRequest(
        logicalFrame: DDCVCPCodec.getFeatureRequest(featureCode: 0x10),
        replyCapacity: 11
      ),
      on: makeAppleSiliconTarget()
    )

    #expect(response.exactFrame == nullReply)
  }

  @Test("oversized reply buffers are rejected before allocation or native calls")
  func oversizedReplyBufferIsRejected() async throws {
    fakeIOAVState.reset(reply: [])
    let transport = try makeTransport()

    let error = await capturedTransportError {
      try await transport.exchange(
        DDCTransportRequest(
          logicalFrame: DDCVCPCodec.getFeatureRequest(featureCode: 0x10),
          replyCapacity: 131
        ),
        on: makeAppleSiliconTarget()
      )
    }

    #expect(
      error
        == .permanentFailure(
          operation: "validate-get-request",
          status: nil
        )
    )
    #expect(fakeIOAVState.eventsSnapshot().isEmpty)
  }

  @Test("a non-DCP target is rejected before resolving or calling IOAV")
  func nonDCPServiceIsRejectedBeforeNativeCalls() async throws {
    fakeIOAVState.reset(reply: [])
    let transport = try makeTransport()

    let error = await capturedTransportError {
      try await transport.exchange(
        DDCTransportRequest(
          logicalFrame: DDCVCPCodec.getFeatureRequest(featureCode: 0x10),
          replyCapacity: 11
        ),
        on: makeAppleSiliconTarget(serviceClass: "IOFramebuffer")
      )
    }

    #expect(
      error
        == .unavailable(
          reason: "The Apple Silicon DDC target is not a DCPAVServiceProxy service."
        )
    )
    #expect(fakeIOAVState.eventsSnapshot().isEmpty)
  }
}

extension AppleSiliconDDCTransportTests {
  @Test("a nil IOAV service is reported and owned handles are released")
  func nilIOAVServiceIsReported() async throws {
    fakeIOAVState.reset(reply: [], createSucceeds: false)
    let transport = try makeTransport()

    let error = await capturedTransportError {
      try await transport.exchange(
        DDCTransportRequest(
          logicalFrame: DDCVCPCodec.getFeatureRequest(featureCode: 0x10),
          replyCapacity: 11
        ),
        on: makeAppleSiliconTarget()
      )
    }

    #expect(
      error
        == .unavailable(
          reason: "IOAVServiceCreateWithService returned no service for the associated DCP proxy."
        )
    )
    let events = fakeIOAVState.eventsSnapshot()
    #expect(events.count(where: { $0 == .releaseRegistryService(0xBEEF) }) == 1)
    #expect(events.count(where: { $0 == .releaseIOAVService }) == 0)
    #expect(events.count(where: isWriteEvent) == 0)
  }

  @Test("write status is not ignored and prevents a read")
  func writeStatusIsNotIgnored() async throws {
    fakeIOAVState.reset(reply: [], writeStatus: kIOReturnBusy)
    let transport = try makeTransport()

    let error = await capturedTransportError {
      try await transport.exchange(
        DDCTransportRequest(
          logicalFrame: DDCVCPCodec.getFeatureRequest(featureCode: 0x10),
          replyCapacity: 11
        ),
        on: makeAppleSiliconTarget()
      )
    }

    #expect(error == .busy)
    let events = fakeIOAVState.eventsSnapshot()
    #expect(events.count(where: isWriteEvent) == 1)
    #expect(events.count(where: isReadEvent) == 0)
    #expect(events.count(where: { $0 == .releaseIOAVService }) == 1)
  }

  @Test("read status is mapped instead of returning zero-filled success")
  func readStatusIsNotIgnored() async throws {
    fakeIOAVState.reset(reply: [], readStatus: kIOReturnTimeout)
    let transport = try makeTransport()

    let error = await capturedTransportError {
      try await transport.exchange(
        DDCTransportRequest(
          logicalFrame: DDCVCPCodec.getFeatureRequest(featureCode: 0x10),
          replyCapacity: 11
        ),
        on: makeAppleSiliconTarget()
      )
    }

    #expect(error == .timedOut)
    let events = fakeIOAVState.eventsSnapshot()
    #expect(events.count(where: isWriteEvent) == 2)
    #expect(events.count(where: isReadEvent) == 1)
    #expect(events.count(where: { $0 == .releaseIOAVService }) == 1)
  }

  @Test("cancellation after write drains one reply before returning")
  func cancellationAfterWriteDrainsReply() async throws {
    fakeIOAVState.reset(
      reply: getFeatureReply(featureCode: 0x10, currentValue: 40)
    )
    let replyGate = TestGate()
    let transport = try makeTransport { _ in
      await replyGate.wait()
    }
    let task = Task {
      try await transport.exchange(
        DDCTransportRequest(
          logicalFrame: DDCVCPCodec.getFeatureRequest(featureCode: 0x10),
          replyCapacity: 11
        ),
        on: makeAppleSiliconTarget()
      )
    }

    var observedWrite = false
    for _ in 0..<1_000 {
      if fakeIOAVState.eventsSnapshot().contains(where: isWriteEvent) {
        observedWrite = true
        break
      }
      await Task.yield()
    }
    #expect(observedWrite)

    task.cancel()
    await replyGate.open()
    do {
      _ = try await task.value
      Issue.record("Expected cancellation after the reply was drained.")
    } catch is CancellationError {
      // Expected: the read completes under the lane, then cancellation wins.
    } catch {
      Issue.record("Unexpected error type: \(error)")
    }

    let events = fakeIOAVState.eventsSnapshot()
    #expect(events.count(where: isWriteEvent) == 2)
    #expect(events.count(where: isReadEvent) == 1)
    #expect(events.count(where: { $0 == .releaseIOAVService }) == 1)
  }

  @Test("zero-filled and truncated successful reads are explicit failures")
  func invalidSuccessfulReadsAreFailures() async throws {
    fakeIOAVState.reset(reply: [])
    let zeroTransport = try makeTransport()
    let zeroError = await capturedTransportError {
      try await zeroTransport.exchange(
        DDCTransportRequest(
          logicalFrame: DDCVCPCodec.getFeatureRequest(featureCode: 0x10),
          replyCapacity: 11
        ),
        on: makeAppleSiliconTarget()
      )
    }
    #expect(zeroError == .noReply)

    fakeIOAVState.reset(reply: [0x6E, 0x88, 0x02, 0x00, 0x10])
    let truncatedTransport = try makeTransport()
    let truncatedError = await capturedTransportError {
      try await truncatedTransport.exchange(
        DDCTransportRequest(
          logicalFrame: DDCVCPCodec.getFeatureRequest(featureCode: 0x10),
          replyCapacity: 5
        ),
        on: makeAppleSiliconTarget()
      )
    }
    #expect(
      truncatedError
        == .transientFailure(
          operation: "IOAVServiceReadI2C-truncated-frame",
          status: nil
        )
    )
  }

  @Test("symbol resolution reports every missing private entry point")
  func symbolResolutionReportsAllMissingSymbols() {
    do {
      _ = try AppleSiliconIOAVFunctionTable { _ in nil }
      Issue.record("Expected missing-symbol failure, but resolution succeeded.")
    } catch let error as AppleSiliconIOAVSymbolError {
      #expect(
        error == .missingSymbols(AppleSiliconIOAVABI.requiredSymbols.sorted())
      )
    } catch {
      Issue.record("Unexpected error type: \(error)")
    }
  }

  #if arch(x86_64)
    @Test("the production factory is unavailable to an x86_64 process")
    func productionFactoryIsUnavailableOnX86() {
      do {
        _ = try AppleSiliconDDCTransport.current()
        Issue.record("Expected an unavailable transport on x86_64.")
      } catch let error as DDCTransportError {
        #expect(
          error
            == .unavailable(
              reason: AppleSiliconIOAVLibraryError.unsupportedArchitecture.transportReason
            )
        )
      } catch {
        Issue.record("Unexpected error type: \(error)")
      }
    }
  #endif
}
