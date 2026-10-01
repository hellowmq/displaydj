import Foundation
import XCTest
import VibeDisplayCore
@testable import DisplayCLI

final class AgentReportContractTests: XCTestCase {
    func testPhaseAndEndPreserveReportFieldsAndSessionEnvelopeWithoutHardwareWrites() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = root.appendingPathComponent(".build/debug/display-cli")
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("displaydj-report-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let phases = Dictionary(uniqueKeysWithValues: AgentPhase.allCases.map { ($0.rawValue, PhaseProfile()) })
        let config = VibeConfig(defaultSelector: "all", phases: phases)
        try JSONCoding.encoder.encode(config).write(to: home.appendingPathComponent("config.json"))
        let session = AgentSession(id: "safe-test", label: "no hardware", client: "test", phase: .starting,
            selector: "all", expiresAt: Date().addingTimeInterval(600))
        let state = PersistedState(sessions: [session])
        try JSONCoding.encoder.encode(state).write(to: home.appendingPathComponent("state.json"))

        for args in [["agent", "phase", session.id, "waiting"], ["agent", "end", session.id]] {
            let process = Process()
            process.executableURL = executable
            process.arguments = args + ["--json"]
            process.environment = ProcessInfo.processInfo.environment.merging(["DISPLAYDJ_HOME": home.path]) { _, new in new }
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output; process.standardError = errors
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            let envelope = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let report = envelope["data"] as! [String: Any]
            XCTAssertEqual((report["session"] as? [String: Any])?["id"] as? String, session.id)
            XCTAssertNotNil(report["brightness"] as? [Any])
            XCTAssertNotNil(report["warnings"] as? [String])
            XCTAssertNotNil(report["keepAwake"] as? [Any])
            XCTAssertTrue((report["brightness"] as? [Any])?.isEmpty == true)
        }
    }
}
