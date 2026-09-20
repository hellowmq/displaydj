import ArgumentParser
import DisplayDJCore
import Foundation

struct DisconnectCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "disconnect",
    abstract: "Stop the window server from outputting to one display.",
    discussion: """
      Disconnecting removes the display from the macOS display layout entirely
      and stops the window server from rendering to it. This is not dimming the
      panel: the desktop space disappears and its windows move to a display that
      is still online.

      The cable stays connected and macOS may bring the display back after a
      wake or unlock, so treat this as a session-scoped change rather than a
      persistent setting.

      Select one display with a stable ID or a `runtime:` ID from
      'displaydj list'. Multi-display selectors are refused, and the last online
      display is never disconnected. Bring it back with 'displaydj connect'.
      """
  )

  @Option(
    name: .customLong("display"),
    help: "Stable ID or runtime:<id> from 'displaydj list'."
  )
  var displayID: String

  @Flag(name: .long, help: "Emit a versioned JSON response.")
  var json = false

  mutating func run() async throws {
    try await DisplayConnectionRunner.run(
      displayID: displayID,
      state: .disconnected,
      json: json
    )
  }
}

struct ConnectCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "connect",
    abstract: "Resume outputting to a display that was disconnected.",
    discussion: """
      Reconnecting adds the display back to the macOS display layout and resumes
      rendering to it.

      A disconnected display is absent from the online topology, so a stable ID
      can only be resolved through the record this tool saves when it
      disconnects a display. If that record is unavailable, reconnect with the
      `runtime:` ID reported by the disconnect command.

      Reconnecting a display that is already online reports success without
      changing anything.
      """
  )

  @Option(
    name: .customLong("display"),
    help: "Stable ID or runtime:<id> from 'displaydj list'."
  )
  var displayID: String

  @Flag(name: .long, help: "Emit a versioned JSON response.")
  var json = false

  mutating func run() async throws {
    try await DisplayConnectionRunner.run(
      displayID: displayID,
      state: .connected,
      json: json
    )
  }
}

enum DisplayConnectionRunner {
  static func run(
    displayID: String,
    state: DisplayConnectionState,
    json: Bool
  ) async throws {
    let selector = try DisplayCLISelector.parse(displayID)
    let controller = try DisplayConnectionController.live()
    let outcome = try await controller.setState(state, for: selector)

    if json {
      FileHandle.standardOutput.write(
        try DisplayConnectionOutput.jsonData(for: outcome)
      )
      FileHandle.standardOutput.write(Data("\n".utf8))
    } else {
      FileHandle.standardOutput.write(
        Data((DisplayConnectionOutput.text(for: outcome) + "\n").utf8)
      )
    }
  }
}

enum DisplayConnectionOutput {
  static func jsonData(for outcome: DisplayConnectionOutcome) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(DisplayConnectionResponse(outcome))
  }

  static func text(for outcome: DisplayConnectionOutcome) -> String {
    let identity = Self.identity(of: outcome.display)
    let headline = "\(outcome.observedState.rawValue)\t\(outcome.display.name) (\(identity))"

    guard outcome.observedState == .disconnected else {
      return headline
    }

    return "\(headline)\nreconnect: displaydj connect --display \(identity)"
  }

  static func identity(of display: DisplayDescriptor) -> String {
    display.stableID ?? "runtime:\(display.runtimeID)"
  }
}

private struct DisplayConnectionResponse: Encodable {
  let schemaVersion = 1
  let isSuccess = true
  let exitCode = CLIExitCode.success.rawValue
  let readOnly = false
  let display: DisplayConnectionDisplayItem
  let requestedState: DisplayConnectionState
  let observedState: DisplayConnectionState
  let wasVerified: Bool
  let reconnectHint: String?

  init(_ outcome: DisplayConnectionOutcome) {
    display = DisplayConnectionDisplayItem(outcome.display)
    requestedState = outcome.requestedState
    observedState = outcome.observedState
    wasVerified = outcome.wasVerified
    reconnectHint =
      outcome.observedState == .disconnected
      ? "displaydj connect --display \(DisplayConnectionOutput.identity(of: outcome.display))"
      : nil
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case isSuccess = "ok"
    case exitCode
    case readOnly
    case display
    case requestedState
    case observedState
    case wasVerified
    case reconnectHint
  }
}

/// A compact identity snapshot for the connection response schema.
private struct DisplayConnectionDisplayItem: Encodable {
  let runtimeID: UInt32
  let stableID: String?
  let name: String
  let isBuiltIn: Bool

  init(_ display: DisplayDescriptor) {
    runtimeID = display.runtimeID
    stableID = display.stableID
    name = display.name
    isBuiltIn = display.isBuiltIn
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(runtimeID, forKey: .runtimeID)
    if let stableID {
      try container.encode(stableID, forKey: .stableID)
    } else {
      try container.encodeNil(forKey: .stableID)
    }
    try container.encode(name, forKey: .name)
    try container.encode(isBuiltIn, forKey: .isBuiltIn)
  }

  private enum CodingKeys: String, CodingKey {
    case runtimeID
    case stableID
    case name
    case isBuiltIn
  }
}
