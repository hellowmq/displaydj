import ArgumentParser

@main
enum DisplayDJMain {
  static func main() async {
    let arguments = Array(CommandLine.arguments.dropFirst())

    do {
      var command = try await DisplayDJCommand.asyncParseAsRoot(arguments)
      if var asyncCommand = command as? AsyncParsableCommand {
        try await asyncCommand.run()
      } else {
        try command.run()
      }
    } catch {
      CLIErrorReporter.terminate(error, arguments: arguments)
    }
  }
}
