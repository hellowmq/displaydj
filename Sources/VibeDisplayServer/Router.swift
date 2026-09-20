import Foundation
import VibeDisplayCore

/// Trivial path router with `:param` segments. Routes are matched in
/// registration order; the first match wins.
public final class Router {
    public typealias Handler = (HTTPRequest, [String: String]) throws -> HTTPResponse

    private struct Route {
        let method: String
        let segments: [String]
        let handler: Handler
    }

    private var routes: [Route] = []

    public init() {}

    public func add(_ method: String, _ pattern: String, _ handler: @escaping Handler) {
        routes.append(Route(method: method.uppercased(),
                            segments: Self.split(pattern),
                            handler: handler))
    }

    public func get(_ pattern: String, _ handler: @escaping Handler) { add("GET", pattern, handler) }
    public func post(_ pattern: String, _ handler: @escaping Handler) { add("POST", pattern, handler) }
    public func put(_ pattern: String, _ handler: @escaping Handler) { add("PUT", pattern, handler) }
    public func delete(_ pattern: String, _ handler: @escaping Handler) { add("DELETE", pattern, handler) }

    public func handle(_ request: HTTPRequest) -> HTTPResponse {
        let path = Self.split(request.path)
        var pathMatchedButWrongMethod = false

        for route in routes {
            guard let params = Self.match(pattern: route.segments, path: path) else { continue }
            guard route.method == request.method else {
                pathMatchedButWrongMethod = true
                continue
            }
            do {
                return try route.handler(request, params)
            } catch let err as VibeError {
                return .failure(err)
            } catch {
                return .failure(VibeError(.backendFailure, "\(error)"))
            }
        }

        if pathMatchedButWrongMethod {
            return .failure(VibeError(.invalidArgument, "method \(request.method) not allowed on \(request.path)"))
        }
        return .failure(VibeError(.routeNotFound, "no route for \(request.method) \(request.path)",
                                  hint: "see docs/API.md or GET /v1/"))
    }

    public var routeTable: [String] {
        routes.map { "\($0.method) /\($0.segments.joined(separator: "/"))" }.sorted()
    }

    private static func split(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    private static func match(pattern: [String], path: [String]) -> [String: String]? {
        guard pattern.count == path.count else { return nil }
        var params: [String: String] = [:]
        for (p, actual) in zip(pattern, path) {
            if p.hasPrefix(":") {
                params[String(p.dropFirst())] = actual.removingPercentEncoding ?? actual
            } else if p != actual {
                return nil
            }
        }
        return params
    }
}
