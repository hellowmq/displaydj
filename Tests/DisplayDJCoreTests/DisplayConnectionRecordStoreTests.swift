import Foundation
import Testing

@testable import DisplayDJCore

@Test("Disconnected-display records follow DISPLAYDJ_HOME")
func connectionRecordsUseIsolatedHome() throws {
  let home = FileManager.default.temporaryDirectory
    .appendingPathComponent("displaydj-connection-record-test-\(UUID().uuidString)", isDirectory: true)
  let store = FileDisplayConnectionRecordStore(
    environment: ["DISPLAYDJ_HOME": home.path]
  )
  let record = DisplayConnectionRecord(runtimeID: 7, stableID: "uuid:test", name: "Test")

  try store.saveRecords([record])

  #expect(FileManager.default.fileExists(atPath: home.appendingPathComponent("disconnected-displays.json").path))
  #expect(try store.loadRecords() == [record])
}
