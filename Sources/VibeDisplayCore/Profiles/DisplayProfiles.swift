import Foundation
import Darwin

public struct DisplayProfileEntry: Codable, Equatable, Sendable {
    public let displayUUID: String
    public let name: String
    public let brightness: Double
    public let transport: BrightnessTransport
}

public struct DisplayProfile: Codable, Equatable, Sendable {
    public let name: String
    public let savedAt: Date
    public let displays: [DisplayProfileEntry]
}

private struct ProfileDocument: Codable {
    var version = 1
    var profiles: [DisplayProfile] = []
}

/// Separate from transient Agent recovery points; all reads and mutations use
/// an advisory process lock and reread disk, so independent CLI saves compose.
public final class DisplayProfileStore {
    public static let shared = DisplayProfileStore()
    private let url: URL
    public init(url: URL = Paths.home.appendingPathComponent("profiles.json")) { self.url = url }

    public static func validateName(_ name: String) throws {
        let allowed = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "-_"))
        guard !name.isEmpty, name.count <= 64,
              name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw VibeError(.invalidArgument, "profile name must contain 1…64 letters, digits, '-' or '_'")
        }
    }

    public func list() throws -> [DisplayProfile] { try transaction { $0.profiles.sorted { $0.name < $1.name } } }
    public func get(_ name: String) throws -> DisplayProfile {
        try Self.validateName(name)
        guard let profile = try list().first(where: { $0.name == name }) else {
            throw VibeError(.invalidArgument, "profile '\(name)' does not exist")
        }
        return profile
    }

    public func save(_ profile: DisplayProfile, replace: Bool = false) throws {
        try Self.validate(profile)
        try transaction(write: true) { document in
            if document.profiles.contains(where: { $0.name == profile.name }), !replace {
                throw VibeError(.invalidArgument, "profile '\(profile.name)' already exists", hint: "use --replace to overwrite it")
            }
            document.profiles.removeAll { $0.name == profile.name }
            document.profiles.append(profile)
        }
    }

    public func delete(_ name: String) throws {
        try Self.validateName(name)
        try transaction(write: true) { document in
            guard document.profiles.contains(where: { $0.name == name }) else {
                throw VibeError(.invalidArgument, "profile '\(name)' does not exist")
            }
            document.profiles.removeAll { $0.name == name }
        }
    }

    private static func validate(_ profile: DisplayProfile) throws {
        try validateName(profile.name)
        guard !profile.displays.isEmpty else { throw VibeError(.configInvalid, "profile contains no displays") }
        var identities = Set<String>()
        for entry in profile.displays {
            guard let uuid = UUID(uuidString: entry.displayUUID), identities.insert(uuid.uuidString).inserted,
                  entry.brightness.isFinite, (0...1).contains(entry.brightness), entry.transport != .none else {
                throw VibeError(.configInvalid, "profile contains duplicate/invalid UUIDs, brightness or transport")
            }
        }
    }

    private func transaction<T>(write: Bool = false, _ body: (inout ProfileDocument) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw VibeError(.ioFailure, "cannot open profile lock") }
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(5)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, Date() < deadline else { throw VibeError(.ioFailure, "profile store is busy or unavailable") }
            usleep(10_000)
        }
        defer { flock(fd, LOCK_UN) }
        var document = ProfileDocument()
        if FileManager.default.fileExists(atPath: url.path) {
            do { document = try JSONCoding.decoder.decode(ProfileDocument.self, from: Data(contentsOf: url)) }
            catch { throw VibeError(.configInvalid, "cannot decode profiles; existing file preserved: \(error)") }
        }
        guard document.version == 1, Set(document.profiles.map(\.name)).count == document.profiles.count else {
            throw VibeError(.configInvalid, "unsupported profile version or duplicate names")
        }
        for profile in document.profiles { try Self.validate(profile) }
        let value = try body(&document)
        if write { try Paths.writeSecure(JSONCoding.encoder.encode(document), to: url) }
        return value
    }
}

public struct ProfileApplyStep: Codable, Sendable {
    public let displayUUID: String
    public let name: String
    public let previous: Double
    public let requested: Double
    public let transport: BrightnessTransport
}

public struct ProfileApplyReport: Codable, Sendable {
    public let name: String
    public let dryRun: Bool
    public let ok: Bool
    public let plan: [ProfileApplyStep]
    public let results: [BrightnessApplyResult]
    public let rollback: [BrightnessApplyResult]
}

public final class DisplayProfileService {
    private let store: DisplayProfileStore
    private let inventory: () -> [DisplayInfo]
    private let readValue: (DisplayInfo) -> Double?
    private let writeValue: (DisplayInfo, Double) -> BrightnessApplyResult
    private let allowsGamma: Bool

    public convenience init(brightness: BrightnessService = .shared, store: DisplayProfileStore = .shared,
                            allowsGamma: Bool = false) {
        self.init(store: store, allowsGamma: allowsGamma,
                  inventory: { brightness.inventory(forceRefresh: true) }, read: { brightness.readOne($0) },
                  write: { brightness.apply(.absolute($1), to: $0, expectedTransport: $0.capability.preferred) })
    }

    init(store: DisplayProfileStore, allowsGamma: Bool = false, inventory: @escaping () -> [DisplayInfo],
         read: @escaping (DisplayInfo) -> Double?, write: @escaping (DisplayInfo, Double) -> BrightnessApplyResult) {
        self.store = store; self.allowsGamma = allowsGamma; self.inventory = inventory
        readValue = read; writeValue = write
    }

    public func save(_ name: String, selector: DisplaySelector, replace: Bool = false) throws -> DisplayProfile {
        try DisplayProfileStore.validateName(name)
        let targets = try selector.resolve(in: inventory())
        guard !targets.isEmpty else { throw VibeError(.displayNotFound, "no displays to save") }
        let entries = try targets.map { display -> DisplayProfileEntry in
            guard UUID(uuidString: display.uuid) != nil, let value = readValue(display), value.isFinite,
                  (0...1).contains(value), display.capability.preferred != .none else {
                throw VibeError(.backendFailure, "cannot capture brightness and stable identity for \(display.name)")
            }
            return DisplayProfileEntry(displayUUID: display.uuid, name: display.name, brightness: value,
                                       transport: display.capability.preferred)
        }
        let profile = DisplayProfile(name: name, savedAt: Date(), displays: entries)
        try store.save(profile, replace: replace)
        return profile
    }

    private func writeChecked(_ saved: DisplayInfo, value: Double) -> BrightnessApplyResult {
        let matches = inventory().filter { $0.uuid.lowercased() == saved.uuid.lowercased() }
        guard matches.count == 1, let live = matches.first, live.capability.preferred == saved.capability.preferred else {
            return BrightnessApplyResult(displayUUID: saved.uuid, slug: saved.slug, requested: value,
                applied: nil, transport: saved.capability.preferred, ok: false,
                error: "display disconnected or changed transport during profile application")
        }
        return writeValue(live, value)
    }

    /// Preflight the whole profile before writing any display. Runtime failures
    /// trigger best-effort reverse-order rollback to this invocation's baseline.
    public func apply(_ name: String, dryRun: Bool = false) throws -> ProfileApplyReport {
        let profile = try store.get(name)
        let current = inventory()
        var targets: [DisplayInfo] = []
        let plan = try profile.displays.map { entry -> ProfileApplyStep in
            let matches = current.filter { $0.uuid.lowercased() == entry.displayUUID.lowercased() }
            guard matches.count == 1, let display = matches.first else {
                throw VibeError(.displayNotFound, "saved display '\(entry.name)' is offline or ambiguous; no profile writes sent")
            }
            guard display.capability.preferred == entry.transport else {
                throw VibeError(.unsupportedOperation, "transport changed for \(entry.name); saved \(entry.transport.rawValue), now \(display.capability.preferred.rawValue)")
            }
            guard dryRun || allowsGamma || entry.transport != .gamma else {
                throw VibeError(.daemonUnavailable, "Gamma profiles require the resident service", hint: "display-cli serve --detach")
            }
            guard let value = readValue(display), value.isFinite, (0...1).contains(value) else {
                throw VibeError(.backendFailure, "cannot read baseline for \(entry.name); no profile writes sent")
            }
            targets.append(display)
            return ProfileApplyStep(displayUUID: display.uuid, name: entry.name, previous: value,
                                    requested: entry.brightness, transport: entry.transport)
        }
        if dryRun { return ProfileApplyReport(name: name, dryRun: true, ok: true, plan: plan, results: [], rollback: []) }
        var results: [BrightnessApplyResult] = []
        for (index, step) in plan.enumerated() {
            let result = writeChecked(targets[index], value: step.requested)
            results.append(result)
            if !result.ok {
                // Include the failed attempt: a failed backend can have mutated.
                let rollback = (0...index).reversed().map { writeChecked(targets[$0], value: plan[$0].previous) }
                return ProfileApplyReport(name: name, dryRun: false, ok: false, plan: plan, results: results, rollback: rollback)
            }
        }
        return ProfileApplyReport(name: name, dryRun: false, ok: true, plan: plan, results: results, rollback: [])
    }
}
