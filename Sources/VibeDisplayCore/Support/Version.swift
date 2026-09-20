import Foundation

public enum VibeVersion {
    /// Single source of truth for the unified CLI and app bundle.
    public static let current = "0.2.1"
    public static let apiVersion = "v1"

    public static var userAgent: String { "display-cli/\(current) (macOS)" }
}
