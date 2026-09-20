import Foundation
import VibeDisplayCore

// Entry point. Keep this file thin: parse, configure global output, dispatch.

let argv = Array(CommandLine.arguments.dropFirst())
let args = Arguments(argv)

Output.json = args.has("json")
Log.jsonMode = Output.json
if args.has("verbose", "v") {
    Log.minimumLevel = .debug
} else if args.has("quiet", "q") {
    Log.minimumLevel = .error
} else {
    Log.minimumLevel = .warn
}

// `--version` parses as a flag, so it never shows up in `positional(0)` and
// would otherwise fall through to the usage dump below and exit 1. Scripts
// probe versions with it, so intercept it before the command guard.
// `-V` is the short form; `-v` stays reserved for `--verbose`.
if args.has("version", "V"), args.positional(0) == nil {
    SystemCommands.version(args)
    exit(0)
}

guard let command = args.positional(0), !args.has("help", "h") else {
    Help.print(exitCode: args.positional(0) == nil && !args.has("help", "h") ? 1 : 0)
}

do {
    switch command {
    case "displays", "list", "ls":
        try DisplayCommands.list(args)

    case "connect", "disconnect":
        try ConnectionCommands.run(args, connected: command == "connect")

    case "capabilities":
        try SystemCommands.doctor(args)

    case "brightness", "b":
        try DisplayCommands.brightness(args)

    case "keepawake", "awake":
        try PowerCommands.keepAwake(args)

    case "agent", "session":
        try AgentCommands.dispatch(args)

    case "serve":
        try DaemonCommands.serve(args)

    case "daemon":
        try DaemonCommands.daemon(args)

    case "doctor", "diagnose":
        try SystemCommands.doctor(args)

    case "config":
        try SystemCommands.config(args)

    case "token":
        try SystemCommands.token(args)

    case "panic", "restore":
        try SystemCommands.panic(args)

    case "version":
        SystemCommands.version(args)

    case "help":
        Help.print(exitCode: 0)

    default:
        Output.fail(VibeError(.invalidArgument, "unknown command '\(command)'",
                              hint: "run `display-cli help`"))
    }
} catch let error as VibeError {
    Output.fail(error)
} catch {
    Output.fail(VibeError(.backendFailure, "\(error)"))
}
