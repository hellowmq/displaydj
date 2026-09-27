import Foundation
import VibeDisplayCore

enum SoftwareDimmingCommands {
    static func run(_ args: Arguments) throws {
        let action = args.positional(1) ?? "get"
        guard ["get", "set", "off"].contains(action) else {
            throw VibeError(.invalidArgument, "use dimming get | set <value> | off")
        }
        try args.validateSurface(options: ["display", "d", "selector"],
                                 maxPositionals: action == "set" ? 3 : 2)
        guard let selector = args.string("display", "d", "selector"), !selector.isEmpty else {
            throw VibeError(.invalidArgument, "dimming requires an explicit --display selector")
        }
        let target: String?
        if action == "set" {
            guard let raw = args.positional(2) else {
                throw VibeError(.invalidArgument, "dimming set requires a value")
            }
            guard case .absolute(let value) = try BrightnessTarget.parse(raw),
                  (GammaBackend.floor...1).contains(value) else {
                throw VibeError(.invalidArgument, "software dimming must be 8%…100%; use off to restore colors")
            }
            target = raw
        } else {
            target = nil
        }
        guard let client = DaemonClient() else {
            throw VibeError(.daemonUnavailable, "software dimming requires the resident service",
                            hint: "display-cli serve --detach")
        }
        if action == "get" {
            let readings = try withCompatibleDaemon {
                try client.decode(ReadingsPayload.self, "GET",
                    "/v1/software-dimming?selector=\(selector.urlPathEncoded)").readings
            }
            Output.emit(ReadingsPayload(readings: readings)) {
                Table.render(headers: ["DISPLAY", "SOFTWARE DIMMING"],
                             rows: readings.map { [$0.slug, Table.percent($0.value)] })
            }
            return
        }
        let results = try withCompatibleDaemon {
            try client.decode(ApplyResultsPayload.self,
                action == "off" ? "DELETE" : "POST",
                action == "off" ? "/v1/software-dimming?selector=\(selector.urlPathEncoded)" : "/v1/software-dimming",
                body: action == "off" ? nil : ["selector": selector, "target": target!]).results
        }
        Output.emit(ApplyResultsPayload(results: results)) {
            Table.render(headers: ["DISPLAY", "SOFTWARE DIMMING", "STATUS"],
                         rows: results.map { [$0.slug, Table.percent($0.applied), $0.error ?? "applied"] })
        }
        if results.contains(where: { !$0.ok }) { exit(1) }
    }

    private static func withCompatibleDaemon<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch let error as VibeError where error.code == .routeNotFound {
            throw VibeError(.unsupportedOperation,
                "当前运行的服务不支持软件调光接口，可能仍是旧版服务",
                hint: "先确认没有未保存的临时显示状态，再运行 display-cli daemon restart")
        }
    }
}
