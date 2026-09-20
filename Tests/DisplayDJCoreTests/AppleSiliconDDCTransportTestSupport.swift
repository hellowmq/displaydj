import CoreFoundation
import Foundation
import IOKit
import Testing

@testable import DisplayDJCore

enum FakeIOAVEvent: Equatable, Sendable {
  case resolve(registryEntryID: UInt64, serviceClass: String)
  case releaseRegistryService(io_service_t)
  case create(registryService: io_service_t)
  case releaseIOAVService
  case write(chipAddress: UInt32, dataAddress: UInt32, bytes: [UInt8])
  case read(chipAddress: UInt32, offset: UInt32, capacity: Int)
}

struct FakeIOAVConfiguration: Sendable {
  let reply: [UInt8]
  let createSucceeds: Bool
  let writeStatus: IOReturn
  let readStatus: IOReturn
}

final class FakeIOAVState: @unchecked Sendable {
  private let lock = NSLock()
  private var configuration = FakeIOAVConfiguration(
    reply: [],
    createSucceeds: true,
    writeStatus: KERN_SUCCESS,
    readStatus: KERN_SUCCESS
  )
  private var events: [FakeIOAVEvent] = []

  func reset(
    reply: [UInt8],
    createSucceeds: Bool = true,
    writeStatus: IOReturn = KERN_SUCCESS,
    readStatus: IOReturn = KERN_SUCCESS
  ) {
    withLock {
      configuration = FakeIOAVConfiguration(
        reply: reply,
        createSucceeds: createSucceeds,
        writeStatus: writeStatus,
        readStatus: readStatus
      )
      events = []
    }
  }

  func recordResolve(_ identity: DDCServiceIdentity) {
    withLock {
      events.append(
        .resolve(
          registryEntryID: identity.registryEntryID,
          serviceClass: identity.serviceClass
        )
      )
    }
  }

  func recordRegistryRelease(_ service: io_service_t) {
    withLock {
      events.append(.releaseRegistryService(service))
    }
  }

  func recordCreate(_ service: io_service_t) -> Bool {
    withLock {
      events.append(.create(registryService: service))
      return configuration.createSucceeds
    }
  }

  func recordIOAVRelease() {
    withLock {
      events.append(.releaseIOAVService)
    }
  }

  func recordWrite(
    chipAddress: UInt32,
    dataAddress: UInt32,
    bytes: [UInt8]
  ) -> IOReturn {
    withLock {
      events.append(
        .write(
          chipAddress: chipAddress,
          dataAddress: dataAddress,
          bytes: bytes
        )
      )
      return configuration.writeStatus
    }
  }

  func recordRead(
    chipAddress: UInt32,
    offset: UInt32,
    capacity: Int
  ) -> (status: IOReturn, reply: [UInt8]) {
    withLock {
      events.append(
        .read(
          chipAddress: chipAddress,
          offset: offset,
          capacity: capacity
        )
      )
      return (configuration.readStatus, configuration.reply)
    }
  }

  func eventsSnapshot() -> [FakeIOAVEvent] {
    withLock { events }
  }

  private func withLock<Result>(_ operation: () -> Result) -> Result {
    lock.lock()
    defer { lock.unlock() }
    return operation()
  }
}

let fakeIOAVState = FakeIOAVState()

final class FakeIOAVServiceToken: NSObject {
  deinit {
    fakeIOAVState.recordIOAVRelease()
  }
}

func fakeCreateWithService(
  _ allocator: CFAllocator?,
  _ registryService: io_service_t
) -> Unmanaged<CFTypeRef>? {
  _ = allocator
  guard fakeIOAVState.recordCreate(registryService) else {
    return nil
  }
  return Unmanaged.passRetained(FakeIOAVServiceToken() as CFTypeRef)
}

func fakeWriteI2C(
  _ service: CFTypeRef,
  _ chipAddress: UInt32,
  _ dataAddress: UInt32,
  _ inputBuffer: UnsafeMutableRawPointer?,
  _ inputBufferSize: UInt32
) -> IOReturn {
  _ = service
  let bytes: [UInt8]
  if let inputBuffer, inputBufferSize > 0 {
    bytes = Array(
      UnsafeBufferPointer(
        start: inputBuffer.assumingMemoryBound(to: UInt8.self),
        count: Int(inputBufferSize)
      )
    )
  } else {
    bytes = []
  }
  return fakeIOAVState.recordWrite(
    chipAddress: chipAddress,
    dataAddress: dataAddress,
    bytes: bytes
  )
}

func fakeReadI2C(
  _ service: CFTypeRef,
  _ chipAddress: UInt32,
  _ offset: UInt32,
  _ outputBuffer: UnsafeMutableRawPointer?,
  _ outputBufferSize: UInt32
) -> IOReturn {
  _ = service
  let result = fakeIOAVState.recordRead(
    chipAddress: chipAddress,
    offset: offset,
    capacity: Int(outputBufferSize)
  )
  guard result.status == KERN_SUCCESS, let outputBuffer else {
    return result.status
  }

  let output = outputBuffer.assumingMemoryBound(to: UInt8.self)
  for index in 0..<Int(outputBufferSize) {
    output[index] = 0
  }
  for (index, byte) in result.reply.prefix(Int(outputBufferSize)).enumerated() {
    output[index] = byte
  }
  return result.status
}

struct FakeAppleSiliconDDCServiceResolver: AppleSiliconDDCServiceResolving {
  let resolvedService: io_service_t
  let error: DDCTransportError?

  init(
    resolvedService: io_service_t = 0xBEEF,
    error: DDCTransportError? = nil
  ) {
    self.resolvedService = resolvedService
    self.error = error
  }

  func resolve(
    _ identity: DDCServiceIdentity
  ) throws -> AppleSiliconDDCResolvedService {
    fakeIOAVState.recordResolve(identity)
    if let error {
      throw error
    }
    return AppleSiliconDDCResolvedService(
      rawValue: resolvedService,
      release: { fakeIOAVState.recordRegistryRelease($0) }
    )
  }
}

func makeTransport(
  resolver: any AppleSiliconDDCServiceResolving = FakeAppleSiliconDDCServiceResolver(),
  replyScheduler: @escaping @Sendable (TimeInterval) async -> Void = { _ in }
) throws -> AppleSiliconDDCTransport {
  AppleSiliconDDCTransport(
    functions: try makeFakeFunctionTable(),
    serviceResolver: resolver,
    replyScheduler: replyScheduler
  )
}

func makeFakeFunctionTable() throws -> AppleSiliconIOAVFunctionTable {
  try AppleSiliconIOAVFunctionTable { symbol in
    switch symbol {
    case AppleSiliconIOAVABI.createWithServiceSymbol:
      unsafeBitCast(
        fakeCreateWithService as AppleSiliconIOAVABI.CreateWithService,
        to: UnsafeMutableRawPointer.self
      )
    case AppleSiliconIOAVABI.readI2CSymbol:
      unsafeBitCast(
        fakeReadI2C as AppleSiliconIOAVABI.ReadI2C,
        to: UnsafeMutableRawPointer.self
      )
    case AppleSiliconIOAVABI.writeI2CSymbol:
      unsafeBitCast(
        fakeWriteI2C as AppleSiliconIOAVABI.WriteI2C,
        to: UnsafeMutableRawPointer.self
      )
    default:
      nil
    }
  }
}

func makeAppleSiliconTarget(
  serviceClass: String = "DCPAVServiceProxy"
) -> DDCTransportTarget {
  DDCTransportTarget(
    display: DisplayDescriptor(
      runtimeID: 42,
      stableID: "uuid:apple-silicon-transport-test",
      name: "Apple Silicon Transport Test Display",
      vendorID: 0x22F0,
      productID: 0x77F3,
      serialNumber: 42,
      isBuiltIn: false,
      isVirtual: false,
      isMirrored: false
    ),
    backend: .appleSiliconDDC,
    service: DDCServiceIdentity(
      registryEntryID: 0xCAFE,
      serviceClass: serviceClass,
      matchBasis: .hardwareTuple
    )
  )
}

func capturedTransportError(
  _ operation: @Sendable () async throws -> DDCTransportResponse
) async -> DDCTransportError? {
  do {
    _ = try await operation()
    Issue.record("Expected DDCTransportError, but the operation succeeded.")
  } catch let error as DDCTransportError {
    return error
  } catch {
    Issue.record("Unexpected error type: \(error)")
  }
  return nil
}

func isWriteEvent(_ event: FakeIOAVEvent) -> Bool {
  if case .write = event {
    return true
  }
  return false
}

func isReadEvent(_ event: FakeIOAVEvent) -> Bool {
  if case .read = event {
    return true
  }
  return false
}
