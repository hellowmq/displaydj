import CoreGraphics
import Darwin
import Foundation

/// Private symbols the display connection controller needs.
///
/// These are resolved at run time rather than linked at build time so the tool
/// keeps working, and keeps reporting an explicit failure, on systems where a
/// private entry point is absent or has been renamed.
public enum DisplayConnectionSymbol: String, CaseIterable, Sendable {
  case configureDisplayEnabled = "CGSConfigureDisplayEnabled"
}

/// Resolves private symbols for the display connection controller.
public protocol DisplayConnectionSymbolResolving: Sendable {
  func resolve(_ symbol: DisplayConnectionSymbol) -> UnsafeMutableRawPointer?
}

/// Resolves symbols from the current process image.
///
/// `RTLD_DEFAULT` is `-2` on Darwin. The lookup never loads a private framework
/// explicitly: SkyLight is already loaded in any GUI session, so a resolved
/// symbol costs nothing and a missing one is simply a miss.
public struct ProcessDisplayConnectionSymbolResolver: DisplayConnectionSymbolResolving {
  public init() {}

  public func resolve(_ symbol: DisplayConnectionSymbol) -> UnsafeMutableRawPointer? {
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbol.rawValue)
  }
}

/// A resolver that reports every lookup as a miss.
///
/// Capability checks and tests use this to prove the controller degrades
/// explicitly instead of skipping the call or reporting a false success.
public struct MissingDisplayConnectionSymbolResolver: DisplayConnectionSymbolResolving {
  public init() {}

  public func resolve(_ symbol: DisplayConnectionSymbol) -> UnsafeMutableRawPointer? {
    nil
  }
}
