import Foundation
import VibeDisplayCore

enum Help {
    static let text = """
    display-cli \(VibeVersion.current) — menu bar + CLI + agent display control for macOS

    USAGE
      display-cli <command> [subcommand] [options]

    DISPLAYS
      displays                          list displays, transports and current brightness
      brightness get [selector]         read brightness
      brightness set <value> [opts]     set brightness — 0.6 | 60% | +10% | -10% | restore
      brightness restore                restore saved brightness (retain failures for retry)
      connect --display uuid:X          reconnect a display
      disconnect --display uuid:X       disconnect one display (never the last online display)
      capabilities                      report available brightness transports

    AGENT LIFECYCLE
      agent run [opts] -- <cmd...>      run a command with the full lifecycle managed
      agent begin --label <text>        open a session, prints the session id
      agent phase <id> <phase>          starting | running | waiting | succeeded | failed
      agent beat <id>                   heartbeat (refreshes session + keep-awake TTL)
      agent end <id> [--outcome ...]    close a session and restore brightness
      agent list [--all]                show sessions

    KEEP AWAKE
      keepawake run -- <cmd...>         hold the screen awake for one command (no daemon)
      keepawake start [opts]            take a lease via the daemon
      keepawake list                    show leases and their TTLs
      keepawake stop <id> | --all       release

    DAEMON
      serve [--port N] [--detach]       run the resident service
      daemon install [--no-load]        start at login, restart on crash (LaunchAgent)
      daemon uninstall                  remove the LaunchAgent again
      daemon status | stop | restart    manage it
      daemon logs [--lines N]           tail the daemon log

    SYSTEM
      doctor                            probe capabilities and print a diagnosis
      config init | show | path | validate
      token show | rotate | path
      panic                             emergency restore of every display
      version

    OPTIONS
      --display, -d <selector>   all | builtin | external | main | #0 | id:N | uuid:X | <slug>
      --ramp <ms>                fade duration for a brightness change
      --ttl <seconds>            session / lease time-to-live
      --beat <seconds>           heartbeat interval for `agent run` (default 30)
      --label <text>             human label for a session
      --client <name>            calling tool; auto-detected when omitted
      --outcome <phase>          terminal phase for `agent end` (default succeeded)
      --scope <display|system|disk>
      --require-ac               suspend the lease while on battery
      --window <HH:mm-HH:mm>     only hold the lease inside this window
      --json                     machine-readable output on stdout
      --verbose / --quiet        log level
      --version, -V              print version, api version and architecture
      --                         everything after this is the wrapped command

    EXAMPLES
      # dim the built-in panel to 40% over half a second
      display-cli brightness set 40% --display builtin --ramp 500

      # run a build with the screen kept awake and brightness managed end to end
      display-cli agent run --label "nightly build" -- make ci

      # manual lifecycle from a shell hook
      SID=$(display-cli agent begin --label "refactor" --json | jq -r .data.session.id)
      display-cli agent phase $SID waiting --note "needs review"
      display-cli agent end $SID --outcome succeeded

      # over HTTP
      display-cli serve --detach
      curl -s -H "Authorization: Bearer $(display-cli token show)" \\
           localhost:7643/v1/displays | jq

    DOCS
      docs/AGENT-INTEGRATION.md   wiring this into Claude Code / Cursor / Codex / CI
      docs/API.md                 CLI and HTTP reference
      docs/ARCHITECTURE.md        how it works and why
    """

    static func print(exitCode: Int32) -> Never {
        if Output.json {
            Swift.print(JSONCoding.string(VibeResponse(data: ["usage": text])))
        } else {
            Swift.print(text)
        }
        exit(exitCode)
    }
}
