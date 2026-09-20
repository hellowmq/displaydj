import Foundation
import Network
import VibeDisplayCore

/// Loopback-only HTTP/1.1 server built on Network.framework.
///
/// Scope is intentionally tiny — it exists so that `curl`, a Python hook, or an
/// MCP shim can drive display-cli without spawning a process per call. It is
/// not a general web server: one request per connection, 1 MiB body cap, bound
/// to 127.0.0.1, bearer-token gated.
public final class HTTPServer {
    public typealias Handler = (HTTPRequest) -> HTTPResponse

    private let host: String
    private let port: Int
    private let token: String?
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.displaydj.http", qos: .userInitiated)
    private var listener: NWListener?
    private let connectionsLock = NSLock()
    private var liveConnections = 0

    public private(set) var boundPort: Int = 0

    public init(host: String, port: Int, token: String?, handler: @escaping Handler) {
        self.host = host
        self.port = port
        self.token = token
        self.handler = handler
    }

    public func start() throws {
        guard ["127.0.0.1", "localhost", "::1"].contains(host) else {
            throw VibeError(.invalidArgument, "host must be a loopback address")
        }
        guard (0...65535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw VibeError(.invalidArgument, "invalid port \(port)")
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Hard guarantee: never reachable from another machine.
        params.requiredInterfaceType = .loopback
        params.acceptLocalOnly = true
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }

        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            throw VibeError(.ioFailure, "cannot bind \(host):\(port): \(error.localizedDescription)",
                            hint: "another daemon may already be running — try `display-cli daemon status`")
        }

        let ready = DispatchSemaphore(value: 0)
        var startupError: Error?

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.boundPort = Int(listener.port?.rawValue ?? 0)
                ready.signal()
            case .failed(let error):
                startupError = error
                ready.signal()
            case .cancelled:
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.start(queue: queue)
        self.listener = listener

        if ready.wait(timeout: .now() + 5) == .timedOut {
            listener.cancel()
            throw VibeError(.ioFailure, "listener did not become ready within 5s")
        }
        if let startupError {
            listener.cancel()
            throw VibeError(.ioFailure, "cannot bind \(host):\(port): \(startupError.localizedDescription)",
                            hint: "another daemon may already be running — try `display-cli daemon status`")
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connectionsLock.lock()
        liveConnections += 1
        let tooMany = liveConnections > 64
        connectionsLock.unlock()

        if tooMany {
            finish(connection, with: HTTPResponse.failure(
                VibeError(.ioFailure, "too many concurrent connections")))
            return
        }

        connection.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                Log.debug("connection failed: \(error)")
            }
        }
        connection.start(queue: queue)
        receive(connection, buffer: Data(), deadline: Date().addingTimeInterval(10))
    }

    private func receive(_ connection: NWConnection, buffer: Data, deadline: Date) {
        guard Date() < deadline else {
            finish(connection, with: HTTPResponse.failure(
                VibeError(.ioFailure, "request timed out")))
            return
        }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            if let error {
                Log.debug("receive error: \(error)")
                self.close(connection)
                return
            }

            var accumulated = buffer
            if let chunk { accumulated.append(chunk) }

            switch HTTPParser.parse(accumulated) {
            case .needMore:
                if isComplete {
                    self.close(connection)
                } else {
                    self.receive(connection, buffer: accumulated, deadline: deadline)
                }
            case .failed(let reason):
                self.finish(connection, with: HTTPResponse.failure(
                    VibeError(.invalidArgument, "bad request: \(reason)")))
            case .complete(let request, _):
                let response = self.dispatch(request)
                self.finish(connection, with: response)
            }
        }
    }

    private func dispatch(_ request: HTTPRequest) -> HTTPResponse {
        let started = Date()
        var response: HTTPResponse

        if let token {
            guard Self.presentedToken(request) == token else {
                response = HTTPResponse.failure(VibeError(
                    .unauthorized, "missing or invalid bearer token",
                    hint: "send `Authorization: Bearer $(cat ~/.displaydj/token)`"))
                logAccess(request, response, started)
                return response
            }
        }

        response = handler(request)
        logAccess(request, response, started)
        return response
    }

    /// Every route requires the token, `/v1/health` included.
    ///
    /// An unauthenticated health endpoint is the conventional choice, and it
    /// was the original design here — a supervisor could liveness-probe
    /// without credentials, and the response "leaks nothing beyond: a daemon
    /// exists". Two things argued it back out:
    ///
    /// * Nothing actually needs it. launchd's `KeepAlive` watches the process,
    ///   not an HTTP endpoint, and the CLI already holds the token. The
    ///   exemption bought a capability no caller used.
    /// * It responds with the version, which is free fingerprinting for any
    ///   local process, and it made "is auth on?" a per-route question rather
    ///   than a property of the server.
    ///
    /// A supervisor that genuinely needs to probe runs as the same user and
    /// can read `~/.displaydj/token`. One rule, no exceptions, is easier to
    /// reason about than one rule and a carve-out.

    private static func presentedToken(_ request: HTTPRequest) -> String? {
        if let auth = request.headers["authorization"] {
            if auth.lowercased().hasPrefix("bearer ") {
                return String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
            return auth.trimmingCharacters(in: .whitespaces)
        }
        if let header = request.headers["x-vibe-token"] { return header }
        return request.query["token"]
    }

    private func logAccess(_ request: HTTPRequest, _ response: HTTPResponse, _ started: Date) {
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        Log.debug("\(request.method) \(request.path) -> \(response.status)", ["ms": "\(ms)"])
    }

    private func finish(_ connection: NWConnection, with response: HTTPResponse) {
        connection.send(content: response.serialize(), completion: .contentProcessed { [weak self] _ in
            self?.close(connection)
        })
    }

    private func close(_ connection: NWConnection) {
        connection.cancel()
        connectionsLock.lock()
        liveConnections = max(0, liveConnections - 1)
        connectionsLock.unlock()
    }
}
