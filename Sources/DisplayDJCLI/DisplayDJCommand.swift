import ArgumentParser
import DisplayDJCore
import VibeDisplayCore

struct DisplayDJCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "displaydj",
    abstract: "A reliable macOS display-control command-line tool.",
    discussion: """
      'set brightness' writes through DDC/CI, reads back to verify, repeats the
      Set frame if the display ignored an isolated write, and restores the
      original baseline on failure. Use 'list' to discover stable IDs or
      current-topology `runtime:` IDs before reading or writing.
      """,
    version: VibeVersion.current,
    subcommands: [
      ListCommand.self,
      GetCommand.self,
      SetCommand.self,
      CapabilitiesCommand.self,
      DoctorCommand.self,
      DisconnectCommand.self,
      ConnectCommand.self,
    ]
  )

  mutating func run() async throws {
    throw CleanExit.helpRequest(self)
  }
}
