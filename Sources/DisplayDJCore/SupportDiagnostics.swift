import Foundation

public enum DiagnosticProduct: String, Codable, Sendable { case full, lite }
public enum DiagnosticReadState: String, Codable, Sendable {
  case supported, unsupported, unknown, unavailable, failed, notChecked = "not-checked"
}

public struct DiagnosticBrightness: Codable, Equatable, Sendable {
  public let transport: BackendKind
  public let state: DiagnosticReadState
  public let error: DisplayDJErrorCode?
  public init(transport: BackendKind, state: DiagnosticReadState, error: DisplayDJErrorCode? = nil) {
    self.transport = transport; self.state = state; self.error = error
  }
}

/// Never accepts raw log text, aliases, paths, tokens or error details.
public struct DiagnosticEvent: Codable, Sendable {
  public let operation: ControlOperation
  public let code: DisplayDJErrorCode
  public let screen: Int?
}

public final class SupportDiagnosticEvents: @unchecked Sendable {
  public static let shared = SupportDiagnosticEvents()
  private let lock = NSLock()
  private var events: [(ControlOperation, DisplayDJErrorCode, String?)] = []
  public init() {}
  public func record(_ error: Error, operation: ControlOperation, stableID: String? = nil) {
    lock.lock(); defer { lock.unlock() }
    events.append((operation, (error as? DisplayDJError)?.code ?? .internalFailure, stableID))
    events = Array(events.suffix(20))
  }
  func snapshot(numbers: [String: Int]) -> [DiagnosticEvent] {
    lock.lock(); defer { lock.unlock() }
    return events.map { DiagnosticEvent(operation: $0.0, code: $0.1, screen: $0.2.flatMap { numbers[$0] }) }
  }
}

public struct SupportDiagnosticReport: Codable, Sendable {
  public struct Screen: Codable, Sendable {
    public let number: Int
    public let online: Bool
    public let builtIn: Bool?
    public let mirrored: Bool?
    public let virtual: Bool?
    public let vendorID: UInt32?
    public let productID: UInt32?
    public let recoveryPending: Bool
    public let requiresRediscovery: Bool
    public let brightness: DiagnosticBrightness?
  }
  public struct Keyboard: Codable, Sendable {
    public let hotkeysEnabled: Bool
    public let mediaKeysEnabled: Bool
    public let accessibilityGranted: Bool
    public init(hotkeysEnabled: Bool, mediaKeysEnabled: Bool, accessibilityGranted: Bool) {
      self.hotkeysEnabled = hotkeysEnabled; self.mediaKeysEnabled = mediaKeysEnabled
      self.accessibilityGranted = accessibilityGranted
    }
  }
  public let schemaVersion: Int
  public let product: DiagnosticProduct
  public let version: String
  public let build: String
  public let operatingSystem: String
  public let architecture: String
  public let simulated: Bool
  public let discoveryError: DisplayDJErrorCode?
  public let recoveryError: DisplayDJErrorCode?
  public let screens: [Screen]
  public let keyboard: Keyboard?
  public let recentErrors: [DiagnosticEvent]

  public func jsonData() throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(self)
  }

  public func save(in directory: URL) throws -> URL {
    let json = try jsonData()
    let folder = directory.appendingPathComponent("DisplayDJ-\(product.rawValue)-diagnostics-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    try json.write(to: folder.appendingPathComponent("report.json"), options: .atomic)
    try text.write(to: folder.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    return folder
  }

  public var text: String {
    var lines = ["DisplayDJ diagnostics / schema \(schemaVersion)",
      "Product: \(product.rawValue) \(version) (\(build))",
      "System: \(operatingSystem) / \(architecture)", "Simulated: \(simulated)",
      "Discovery: \(discoveryError?.rawValue ?? "completed")",
      "Recovery records: \(recoveryError?.rawValue ?? "read")"]
    if screens.isEmpty { lines.append("No screens were reported; external hardware was not verified.") }
    for screen in screens {
      lines.append("Screen \(screen.number): \(screen.online ? "online" : "offline"), recovery=\(screen.recoveryPending), rediscovery=\(screen.requiresRediscovery)")
      lines.append("  Built-in: \(screen.builtIn.map { String($0) } ?? "unknown"), mirror: \(screen.mirrored.map { String($0) } ?? "unknown"), virtual: \(screen.virtual.map { String($0) } ?? "unknown")")
      lines.append("  Vendor/model: \(screen.vendorID.map(String.init) ?? "unknown") / \(screen.productID.map(String.init) ?? "unknown")")
      if let brightness = screen.brightness {
        lines.append("  Brightness: \(brightness.transport.rawValue) / \(brightness.state.rawValue) / \(brightness.error?.rawValue ?? "none")")
      }
    }
    if let keyboard { lines.append("Keyboard: hotkeys=\(keyboard.hotkeysEnabled), mediaKeys=\(keyboard.mediaKeysEnabled), accessibility=\(keyboard.accessibilityGranted)") }
    for event in recentErrors { lines.append("Error: screen=\(event.screen.map(String.init) ?? "unknown"), \(event.operation.rawValue) / \(event.code.rawValue)") }
    return lines.joined(separator: "\n") + "\n"
  }
}

/// Collects only an allowlisted projection. Untrusted messages and nested error
/// details never enter the report, so redaction does not depend on regexes.
public struct SupportDiagnosticCollector: Sendable {
  public let discovery: any DisplayDiscovering
  public let store: any DisplayConnectionRecordStoring
  public let readBrightness: @Sendable (DisplayDescriptor) async -> DiagnosticBrightness
  public let events: SupportDiagnosticEvents

  public init(discovery: any DisplayDiscovering, store: any DisplayConnectionRecordStoring,
    events: SupportDiagnosticEvents = .shared,
    readBrightness: @escaping @Sendable (DisplayDescriptor) async -> DiagnosticBrightness) {
    self.discovery = discovery; self.store = store; self.events = events; self.readBrightness = readBrightness
  }

  public func collect(product: DiagnosticProduct, version: String, build: String,
    keyboard: SupportDiagnosticReport.Keyboard? = nil, simulated: Bool = false) async throws -> SupportDiagnosticReport {
    var displays: [DisplayDescriptor] = []
    var records: [DisplayConnectionRecord] = []
    var discoveryError: DisplayDJErrorCode?
    var recoveryError: DisplayDJErrorCode?
    do { displays = try await discovery.discoverDisplays() }
    catch { discoveryError = (error as? DisplayDJError)?.code ?? .internalFailure }
    do { records = try store.loadRecords() }
    catch { recoveryError = (error as? DisplayDJError)?.code ?? .internalFailure }
    try Task.checkCancellation()
    var screens: [SupportDiagnosticReport.Screen] = []
    var numbers: [String: Int] = [:]
    for display in displays {
      let number = screens.count + 1
      if let id = display.stableID { numbers[id] = number }
      let matching = records.filter { $0.stableID != nil && $0.stableID == display.stableID }
      let brightness = await readBrightness(display)
      try Task.checkCancellation()
      screens.append(.init(number: number, online: true, builtIn: display.isBuiltIn,
        mirrored: display.isMirrored, virtual: display.isVirtual, vendorID: display.vendorID, productID: display.productID,
        recoveryPending: !matching.isEmpty,
        requiresRediscovery: matching.contains { $0.requiresRediscovery == true }, brightness: brightness))
    }
    for record in records where record.stableID == nil || numbers[record.stableID!] == nil {
      let number = screens.count + 1
      if let id = record.stableID { numbers[id] = number }
      screens.append(.init(number: number, online: false, builtIn: nil, mirrored: nil, virtual: nil,
        vendorID: nil, productID: nil,
        recoveryPending: true, requiresRediscovery: record.requiresRediscovery == true, brightness: nil))
    }
    #if arch(arm64)
    let architecture = "arm64"
    #elseif arch(x86_64)
    let architecture = "x86_64"
    #else
    let architecture = "unknown"
    #endif
    return SupportDiagnosticReport(schemaVersion: 1, product: product, version: version, build: build,
      operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString, architecture: architecture,
      simulated: simulated, discoveryError: discoveryError, recoveryError: recoveryError, screens: screens,
      keyboard: product == .full ? keyboard : nil, recentErrors: events.snapshot(numbers: numbers))
  }
}
