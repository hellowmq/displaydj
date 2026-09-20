import Foundation

/// Machine-readable environment report. Backs `display-cli doctor` and
/// `GET /v1/capabilities`.
///
/// The point of this type is that a user filing a bug, an agent deciding
/// whether hardware dimming is available, and CI asserting the build works all
/// read the *same* structure.
public struct CapabilitiesReport: Codable, Equatable, Sendable {
    public let platform: String
    public let architecture: String
    public let osVersion: String
    public let version: String
    public let displayServicesAvailable: Bool
    public let ddcAvailable: Bool
    public let ddcEngine: String
    public let daemonRunning: Bool
    public let daemonURL: String?
    public let configPath: String
    public let statePath: String
    public let displays: [DisplayInfo]
    public let warnings: [String]

    /// `true` when at least one display can be driven by real hardware
    /// backlight control (not gamma). Agents can branch on this.
    public var hasHardwareControl: Bool {
        displays.contains { $0.capability.preferred.isHardware }
    }
}

public enum Diagnostics {
    public static func capabilities(brightness: BrightnessService = .shared) -> CapabilitiesReport {
        let displays = brightness.inventory(forceRefresh: true)
        var warnings: [String] = []

        if displays.isEmpty {
            warnings.append("no displays detected — is this running in a headless session?")
        }
        if !brightness.displayServices.isAvailable {
            warnings.append("DisplayServices private framework not resolvable; built-in panel falls back to gamma dimming")
        }
        #if !arch(arm64)
        warnings.append("DDC/CI on Intel Macs is not implemented (roadmap task `ddc-intel`); external panels use gamma dimming")
        #endif

        let gammaOnly = displays.filter { $0.capability.preferred == .gamma }
        if !gammaOnly.isEmpty {
            warnings.append("gamma-only displays (\(gammaOnly.map(\.slug).joined(separator: ", "))) require `display-cli serve` to keep dimming applied")
        }

        let daemon = DaemonDescriptor.loadIfAlive()

        return CapabilitiesReport(
            platform: "macOS",
            architecture: currentArchitecture,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            version: VibeVersion.current,
            displayServicesAvailable: brightness.displayServices.isAvailable,
            ddcAvailable: displays.contains { $0.capability.preferred == .ddc },
            ddcEngine: "DisplayDJCore / identity-matched IOAV",
            daemonRunning: daemon != nil,
            daemonURL: daemon?.baseURL,
            configPath: Paths.configFile.path,
            statePath: Paths.stateFile.path,
            displays: displays,
            warnings: warnings
        )
    }

    public static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
