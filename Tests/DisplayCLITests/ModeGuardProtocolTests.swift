import Foundation
import XCTest
@testable import DisplayCLI

final class ModeGuardProtocolTests: XCTestCase {
    func testOnlyExactKeepCommandConfirms() throws {
        let input = Pipe()
        input.fileHandleForWriting.write(Data("keep\n".utf8))
        XCTAssertEqual(ModeCommands.waitForDecision(seconds: 0.2,
                                                       inputFD: input.fileHandleForReading.fileDescriptor), .keep)
    }

    func testUnknownCommandRestores() throws {
        let input = Pipe()
        input.fileHandleForWriting.write(Data("keep please\n".utf8))
        XCTAssertEqual(ModeCommands.waitForDecision(seconds: 0.2,
                                                       inputFD: input.fileHandleForReading.fileDescriptor), .restore)
    }

    func testParentPipeClosingRestores() throws {
        let input = Pipe()
        try input.fileHandleForWriting.close()
        XCTAssertEqual(ModeCommands.waitForDecision(seconds: 0.2,
                                                       inputFD: input.fileHandleForReading.fileDescriptor), .restore)
    }

    func testTimeoutRestores() throws {
        let input = Pipe()
        XCTAssertEqual(ModeCommands.waitForDecision(seconds: 0.02,
                                                       inputFD: input.fileHandleForReading.fileDescriptor), .restore)
    }
}
