import Foundation
import VibeDisplayCore

public struct HTTPRequest {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let headers: [String: String]
    public let body: Data

    public func json<T: Decodable>(_ type: T.Type) throws -> T {
        guard !body.isEmpty else {
            throw VibeError(.invalidArgument, "request body is empty")
        }
        do {
            return try JSONCoding.decoder.decode(type, from: body)
        } catch {
            throw VibeError(.invalidArgument, "malformed JSON body: \(error)")
        }
    }

    /// Body field, falling back to the query string. Lets everything be driven
    /// from `curl` without a JSON payload:
    /// `curl -X POST '.../phase?phase=running'`
    public func value(_ key: String) -> String? {
        if let q = query[key] { return q }
        guard !body.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let raw = object[key] else { return nil }
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }
}

public struct HTTPResponse {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json<T: Encodable>(_ payload: T, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONCoding.encoder.encode(payload)) ?? Data("{}".utf8)
        return HTTPResponse(status: status,
                            headers: ["Content-Type": "application/json; charset=utf-8"],
                            body: data)
    }

    public static func ok<T: Encodable>(_ payload: T) -> HTTPResponse {
        json(VibeResponse(data: payload))
    }

    public static func failure(_ error: VibeError) -> HTTPResponse {
        let status: Int
        switch error.code {
        case .invalidArgument, .configInvalid, .ambiguousSelector: status = 400
        case .unauthorized: status = 401
        case .displayNotFound, .sessionNotFound, .routeNotFound: status = 404
        case .sessionConflict, .daemonAlreadyRunning: status = 409
        case .unsupportedOperation, .notImplemented: status = 501
        case .daemonUnavailable: status = 503
        default: status = 500
        }
        return json(VibeResponse<EmptyPayload>(error: error), status: status)
    }

    var statusText: String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        case 501: return "Not Implemented"
        default: return "Status"
        }
    }

    func serialize() -> Data {
        var head = "HTTP/1.1 \(status) \(statusText)\r\n"
        var merged = headers
        merged["Content-Length"] = "\(body.count)"
        merged["Connection"] = "close"
        merged["Server"] = VibeVersion.userAgent
        for (k, v) in merged.sorted(by: { $0.key < $1.key }) {
            head += "\(k): \(v)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

/// Incremental HTTP/1.1 request parser. Deliberately minimal: loopback only,
/// no chunked encoding, no keep-alive, hard body cap.
struct HTTPParser {
    static let maxBodyBytes = 1 << 20   // 1 MiB

    enum Outcome {
        case needMore
        case complete(HTTPRequest, consumed: Int)
        case failed(String)
    }

    static func parse(_ buffer: Data) -> Outcome {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > 64 * 1024 ? .failed("header section too large") : .needMore
        }
        let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .failed("headers are not valid UTF-8")
        }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .failed("empty request") }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { return .failed("malformed request line") }

        let method = String(requestLine[0]).uppercased()
        let target = String(requestLine[1])

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard contentLength <= maxBodyBytes else { return .failed("body exceeds 1 MiB") }

        let bodyStart = headerEnd.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= contentLength else { return .needMore }

        let bodyEnd = buffer.index(bodyStart, offsetBy: contentLength)
        let body = Data(buffer[bodyStart..<bodyEnd])

        var path = target
        var query: [String: String] = [:]
        if let qmark = target.firstIndex(of: "?") {
            path = String(target[target.startIndex..<qmark])
            let raw = String(target[target.index(after: qmark)...])
            for pair in raw.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let value = kv.count > 1 ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "") : ""
                query[key] = value
            }
        }

        let consumed = buffer.distance(from: buffer.startIndex, to: bodyEnd)
        return .complete(HTTPRequest(method: method, path: path, query: query,
                                     headers: headers, body: body),
                         consumed: consumed)
    }
}
