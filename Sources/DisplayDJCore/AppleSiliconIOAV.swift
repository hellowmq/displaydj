import CoreFoundation
import Darwin
import IOKit

/// The dynamically resolved private ABI used by the Apple Silicon DDC adapter.
/// Keeping these exact C-compatible types in one place makes pointer casts
/// auditable and prevents an availability check from outliving its dlopen handle.
enum AppleSiliconIOAVABI {
  static let frameworkPath = "/System/Library/Frameworks/IOKit.framework/IOKit"
  static let createWithServiceSymbol = "IOAVServiceCreateWithService"
  static let readI2CSymbol = "IOAVServiceReadI2C"
  static let writeI2CSymbol = "IOAVServiceWriteI2C"
  static let requiredSymbols = [
    createWithServiceSymbol,
    readI2CSymbol,
    writeI2CSymbol,
  ]

  typealias CreateWithService =
    @convention(c) (
      CFAllocator?,
      io_service_t
    ) -> Unmanaged<CFTypeRef>?

  typealias ReadI2C =
    @convention(c) (
      CFTypeRef,
      UInt32,
      UInt32,
      UnsafeMutableRawPointer?,
      UInt32
    ) -> IOReturn

  typealias WriteI2C =
    @convention(c) (
      CFTypeRef,
      UInt32,
      UInt32,
      UnsafeMutableRawPointer?,
      UInt32
    ) -> IOReturn
}

/// Immutable C function pointers are safe to share. The unchecked conformance is
/// limited to this audited ABI table; no raw library handle is exposed.
struct AppleSiliconIOAVFunctionTable: @unchecked Sendable {
  let createWithService: AppleSiliconIOAVABI.CreateWithService
  let readI2C: AppleSiliconIOAVABI.ReadI2C
  let writeI2C: AppleSiliconIOAVABI.WriteI2C

  init(
    resolve: (String) -> UnsafeMutableRawPointer?
  ) throws {
    let createAddress = resolve(AppleSiliconIOAVABI.createWithServiceSymbol)
    let readAddress = resolve(AppleSiliconIOAVABI.readI2CSymbol)
    let writeAddress = resolve(AppleSiliconIOAVABI.writeI2CSymbol)

    let missingSymbols = [
      (AppleSiliconIOAVABI.createWithServiceSymbol, createAddress),
      (AppleSiliconIOAVABI.readI2CSymbol, readAddress),
      (AppleSiliconIOAVABI.writeI2CSymbol, writeAddress),
    ].compactMap { name, address in
      address == nil ? name : nil
    }
    guard
      missingSymbols.isEmpty,
      let createAddress,
      let readAddress,
      let writeAddress
    else {
      throw AppleSiliconIOAVSymbolError.missingSymbols(missingSymbols.sorted())
    }

    createWithService = unsafeBitCast(
      createAddress,
      to: AppleSiliconIOAVABI.CreateWithService.self
    )
    readI2C = unsafeBitCast(
      readAddress,
      to: AppleSiliconIOAVABI.ReadI2C.self
    )
    writeI2C = unsafeBitCast(
      writeAddress,
      to: AppleSiliconIOAVABI.WriteI2C.self
    )
  }
}

enum AppleSiliconIOAVSymbolError: Error, Equatable, Sendable {
  case missingSymbols([String])
}

enum AppleSiliconIOAVLibraryError: Error, Equatable, Sendable {
  case unsupportedArchitecture
  case frameworkUnavailable(path: String)
  case missingSymbols(path: String, symbols: [String])

  var transportReason: String {
    switch self {
    case .unsupportedArchitecture:
      "The Apple Silicon IOAV transport is available only to an arm64 process."
    case .frameworkUnavailable(let path):
      "The private IOAV transport framework could not be loaded at \(path)."
    case .missingSymbols(let path, let symbols):
      "The private IOAV transport at \(path) is missing: \(symbols.joined(separator: ", "))."
    }
  }
}

/// Owns the dlopen handle for at least as long as any resolved function pointer
/// can be called. The handle and pointers are immutable after initialization.
final class AppleSiliconIOAVLibrary: @unchecked Sendable {
  let functions: AppleSiliconIOAVFunctionTable

  private let handle: UnsafeMutableRawPointer

  private init(
    handle: UnsafeMutableRawPointer,
    functions: AppleSiliconIOAVFunctionTable
  ) {
    self.handle = handle
    self.functions = functions
  }

  static func open(
    path: String = AppleSiliconIOAVABI.frameworkPath
  ) throws -> AppleSiliconIOAVLibrary {
    #if arch(arm64)
      guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else {
        throw AppleSiliconIOAVLibraryError.frameworkUnavailable(path: path)
      }

      do {
        let functions = try AppleSiliconIOAVFunctionTable { symbol in
          symbol.withCString { dlsym(handle, $0) }
        }
        return AppleSiliconIOAVLibrary(handle: handle, functions: functions)
      } catch let error as AppleSiliconIOAVSymbolError {
        dlclose(handle)
        switch error {
        case .missingSymbols(let symbols):
          throw AppleSiliconIOAVLibraryError.missingSymbols(
            path: path,
            symbols: symbols
          )
        }
      } catch {
        dlclose(handle)
        throw error
      }
    #else
      throw AppleSiliconIOAVLibraryError.unsupportedArchitecture
    #endif
  }

  deinit {
    dlclose(handle)
  }
}

protocol AppleSiliconDDCServiceResolving: Sendable {
  func resolve(
    _ identity: DDCServiceIdentity
  ) throws -> AppleSiliconDDCResolvedService
}

/// Owns one I/O Registry service send right and releases it exactly once.
final class AppleSiliconDDCResolvedService: @unchecked Sendable {
  let rawValue: io_service_t

  private let release: @Sendable (io_service_t) -> Void

  init(
    rawValue: io_service_t,
    release: @escaping @Sendable (io_service_t) -> Void
  ) {
    self.rawValue = rawValue
    self.release = release
  }

  deinit {
    release(rawValue)
  }
}

/// Re-resolves a run-scoped registry entry ID instead of treating the UInt64 ID
/// as an io_service_t handle. The exact service class and entry ID are checked
/// again because the display topology may have changed after association.
struct IOKitAppleSiliconDDCServiceResolver: AppleSiliconDDCServiceResolving {
  func resolve(
    _ identity: DDCServiceIdentity
  ) throws -> AppleSiliconDDCResolvedService {
    let service = try matchingService(for: identity.registryEntryID)
    var ownsService = true
    defer {
      if ownsService {
        IOObjectRelease(service)
      }
    }

    try validate(service: service, matches: identity)
    ownsService = false
    return AppleSiliconDDCResolvedService(
      rawValue: service,
      release: { IOObjectRelease($0) }
    )
  }

  private func matchingService(
    for registryEntryID: UInt64
  ) throws -> io_service_t {
    guard registryEntryID != 0 else {
      throw DDCTransportError.unavailable(
        reason: "The associated DCP service has an invalid zero registry entry ID."
      )
    }
    guard let matching = IORegistryEntryIDMatching(registryEntryID) else {
      throw DDCTransportError.permanentFailure(
        operation: "IORegistryEntryIDMatching",
        status: kIOReturnNoMemory
      )
    }

    let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
    guard service != IO_OBJECT_NULL else {
      throw DDCTransportError.unavailable(
        reason: "The associated DCP service is no longer present in the I/O Registry."
      )
    }
    return service
  }

  private func validate(
    service: io_service_t,
    matches identity: DDCServiceIdentity
  ) throws {
    let actualClass = try serviceClass(of: service)
    guard actualClass == identity.serviceClass else {
      throw DDCTransportError.unavailable(
        reason: [
          "The associated registry entry now has class \(actualClass)",
          "instead of \(identity.serviceClass).",
        ].joined(separator: " ")
      )
    }

    var actualRegistryEntryID: UInt64 = 0
    let status = IORegistryEntryGetRegistryEntryID(
      service,
      &actualRegistryEntryID
    )
    guard status == KERN_SUCCESS else {
      throw DDCTransportError.permanentFailure(
        operation: "IORegistryEntryGetRegistryEntryID",
        status: status
      )
    }
    guard actualRegistryEntryID == identity.registryEntryID else {
      throw DDCTransportError.unavailable(
        reason: "The resolved DCP service registry entry ID changed before use."
      )
    }
  }

  private func serviceClass(
    of service: io_service_t
  ) throws -> String {
    let capacity = MemoryLayout<io_name_t>.size
    let name = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
    defer { name.deallocate() }

    let status = IOObjectGetClass(service, name)
    guard status == KERN_SUCCESS else {
      throw DDCTransportError.permanentFailure(
        operation: "IOObjectGetClass",
        status: status
      )
    }
    return String(cString: name)
  }
}
