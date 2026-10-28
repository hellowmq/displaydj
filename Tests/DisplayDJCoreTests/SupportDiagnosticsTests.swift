import Foundation
import Testing
@testable import DisplayDJCore

private struct DiagnosticDiscovery: DisplayDiscovering {
  var displays: [DisplayDescriptor] = []
  var failure: DisplayDJError?
  func discoverDisplays() async throws -> [DisplayDescriptor] {
    if let failure { throw failure }; return displays
  }
}

struct SupportDiagnosticsTests {
  @Test func savesBothFormatsInANewDirectoryAndReportsAnInvalidDestination() async throws {
    let collector = SupportDiagnosticCollector(discovery: DiagnosticDiscovery(),
      store: InMemoryDisplayConnectionRecordStore(), readBrightness: { _ in .init(transport: .nativeBrightness, state: .unknown) })
    let report = try await collector.collect(product: .lite, version: "0.1.0", build: "test")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let first = try report.save(in: directory)
    let second = try report.save(in: directory)
    #expect(first != second)
    #expect(try Data(contentsOf: first.appendingPathComponent("report.json")) == report.jsonData())
    #expect(try String(contentsOf: first.appendingPathComponent("report.txt"), encoding: .utf8) == report.text)
    do { _ = try report.save(in: first.appendingPathComponent("report.txt")); Issue.record("Destination is a file") }
    catch { #expect(error is CocoaError) }
  }

  let secret = "uuid:aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  func display() -> DisplayDescriptor {
    .init(runtimeID: 777, stableID: secret, name: "Private Desk /Users/alice",
      serialNumber: 987654321, isBuiltIn: false, isVirtual: false, isMirrored: false)
  }

  @Test func exportedReportNeverCopiesRawIdentityPathsOrNestedErrorText() async throws {
    let events = SupportDiagnosticEvents()
    let failure = DisplayDJError(code: .transportFailure, message: "Bearer SECRET /Users/alice",
      displayID: secret, details: ["nested": "token=SECRET serial=987654321"])
    events.record(failure, operation: .write, stableID: secret)
    let record = DisplayConnectionRecord(runtimeID: 777, stableID: secret, name: "Private Desk")
    let store = InMemoryDisplayConnectionRecordStore(records: [record])
    let collector = SupportDiagnosticCollector(discovery: DiagnosticDiscovery(displays: [display()]),
      store: store, events: events, readBrightness: { _ in .init(transport: .appleSiliconDDC, state: .failed, error: .transportFailure) })
    let report = try await collector.collect(product: .lite, version: "0.1.0", build: "candidate")
    let output = String(decoding: try report.jsonData(), as: UTF8.self) + report.text
    for value in [secret, "777", "Private Desk", "/Users", "alice", "SECRET", "987654321", "token="] {
      #expect(!output.contains(value))
    }
    #expect(report.screens.count == 1 && report.screens[0].recoveryPending)
    #expect(report.recentErrors.first?.screen == 1)
    #expect(report.recentErrors.first?.code == .transportFailure)
    #expect(try store.loadRecords() == [record])
  }

  @Test func failedDiscoveryStillExportsRecoveryRecordsAndDoesNotClaimHardwareSuccess() async throws {
    let record = DisplayConnectionRecord(runtimeID: 99, stableID: secret, name: "Private Desk")
    let collector = SupportDiagnosticCollector(discovery: DiagnosticDiscovery(failure: .init(code: .timeout, message: "private")),
      store: InMemoryDisplayConnectionRecordStore(records: [record]), readBrightness: { _ in
        Issue.record("No brightness probe should run after failed discovery")
        return .init(transport: .appleSiliconDDC, state: .supported)
      })
    let report = try await collector.collect(product: .full, version: "1.0.2", build: "unknown")
    #expect(report.discoveryError == .timeout)
    #expect(report.screens.count == 1 && !report.screens[0].online)
    #expect(report.screens[0].brightness == nil)
  }

  @Test func unreadableRecordsAreReportedWithoutRewritingTheFile() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("records.json")
    let bytes = Data("{private: invalid-json}".utf8); try bytes.write(to: url)
    let collector = SupportDiagnosticCollector(discovery: DiagnosticDiscovery(),
      store: FileDisplayConnectionRecordStore(fileURL: url), readBrightness: { _ in
        Issue.record("No display to probe"); return .init(transport: .nativeBrightness, state: .unknown)
      })
    let report = try await collector.collect(product: .lite, version: "0.1.0", build: "unknown",
      keyboard: .init(hotkeysEnabled: true, mediaKeysEnabled: true, accessibilityGranted: true))
    #expect(report.recoveryError == .internalFailure)
    #expect(report.keyboard == nil && report.screens.isEmpty)
    #expect(try Data(contentsOf: url) == bytes)
    #expect(!String(decoding: try report.jsonData(), as: UTF8.self).contains(directory.path))
  }
}
