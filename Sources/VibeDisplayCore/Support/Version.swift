import Foundation

public enum VibeVersion {
    /// Single source of truth for the unified CLI and app bundle.
    public static let current = "1.0.0"
    public static let apiVersion = "v1"

    public static var userAgent: String { "display-cli/\(current) (macOS)" }
}
