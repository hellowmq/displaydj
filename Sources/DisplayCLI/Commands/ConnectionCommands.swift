import Foundation
import DisplayDJCore
import VibeDisplayCore

enum ConnectionCommands {
    static func run(_ args: Arguments, connected: Bool) throws {
        guard let raw = args.string("display", "d"), !raw.isEmpty else {
            throw VibeError(.invalidArgument, "--display is required", hint: "use uuid:<UUID> from `display-cli displays`")
        }
        do {
            let selector = try DisplayCLISelector.parse(raw)
            let outcome = try SynchronousTask.run {
                try await DisplayConnectionController.live().setState(
                    connected ? .connected : .disconnected, for: selector)
            }
            Output.emit(outcome) { "\(outcome.display.name): \(outcome.observedState.rawValue)" }
        } catch let error as DisplayDJError {
            let code: VibeError.Code
            switch error.code {
            case .invalidArguments, .invalidValue, .invalidSelector: code = .invalidArgument
            case .ambiguousDisplay: code = .ambiguousSelector
            case .displayNotFound: code = .displayNotFound
            case .unsupported, .backendUnavailable: code = .unsupportedOperation
            default: code = .backendFailure
            }
            throw VibeError(code, error.message, hint: error.details["reason"])
        }
    }
}
