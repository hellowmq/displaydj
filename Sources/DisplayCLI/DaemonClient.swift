import Foundation
import VibeDisplayCore

/// Synchronous HTTP client for the local daemon.
///
/// ## Why the CLI talks to the daemon at all
///
/// Gamma tables and `IOPMAssertion`s are owned by the process that created
/// them and vanish when it exits. A one-shot `display-cli` invocation is that
/// process. So whenever a daemon is running, the CLI *delegates* instead of
/// acting locally — that way the effect outlives the command.
///
/// When no daemon is running the CLI acts locally and warns if the requested
/// operation needs residency. It never silently no-ops.
struct DaemonClient {
    let descriptor: DaemonDescriptor
    let token: String?
    let timeout: TimeInterval

    init?(timeout: TimeInterval = 10) {
        guard let descriptor = DaemonDescriptor.loadIfAlive() else { return nil }
        self.descriptor = descriptor
        self.token = descriptor.requiresToken ? TokenStore.load() : nil
        self.timeout = timeout
    }

    /// Raw JSON object from the `data` field of the envelope.
    @discardableResult
    func call(_ method: String, _ path: String, body: [String: Any]? = nil) throws -> Any {
        guard let url = URL(string: descriptor.baseURL + path) else {
            throw VibeError(.invalidArgument, "bad daemon url for path \(path)")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(VibeVersion.userAgent, forHTTPHeaderField: "User-Agent")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        var payload: Data?
        var failure: Error?
        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            payload = data
            failure = error
            semaphore.signal()
        }
        task.resume()

        if semaphore.wait(timeout: .now() + timeout + 2) == .timedOut {
            task.cancel()
            throw VibeError(.daemonUnavailable, "daemon did not respond within \(Int(timeout))s")
        }
        if let failure {
            throw VibeError(.daemonUnavailable, "daemon request failed: \(failure.localizedDescription)",
                            hint: "the daemon may have died — try `display-cli daemon status`")
        }
        guard let payload, !payload.isEmpty else {
            throw VibeError(.daemonUnavailable, "daemon returned an empty response")
        }
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw VibeError(.backendFailure, "daemon returned malformed JSON")
        }
        if object["ok"] as? Bool == true {
            return object["data"] ?? [:]
        }
        if let errorDict = object["error"] as? [String: Any] {
            let code = VibeError.Code(rawValue: errorDict["code"] as? String ?? "") ?? .backendFailure
            throw VibeError(code,
                            errorDict["message"] as? String ?? "daemon error",
                            hint: errorDict["hint"] as? String)
        }
        throw VibeError(.backendFailure, "unexpected daemon response")
    }

    /// Decode the `data` field into a concrete type.
    func decode<T: Decodable>(_ type: T.Type, _ method: String, _ path: String,
                              body: [String: Any]? = nil) throws -> T {
        let raw = try call(method, path, body: body)
        let data = try JSONSerialization.data(withJSONObject: raw)
        do {
            return try JSONCoding.decoder.decode(type, from: data)
        } catch {
            throw VibeError(.backendFailure, "cannot decode daemon response as \(type): \(error)")
        }
    }

    static func isRunning() -> Bool { DaemonDescriptor.loadIfAlive() != nil }
}
