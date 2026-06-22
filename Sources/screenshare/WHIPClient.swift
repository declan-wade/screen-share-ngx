import Foundation

/// Minimal WHIP (WebRTC-HTTP Ingestion Protocol, RFC 9725) client.
/// Single HTTP POST: offer SDP up, answer SDP down. No WebSocket signaling.
struct WHIPClient {
    let endpoint: String

    struct Result {
        let answerSDP: String
        let resourceURL: URL?   // Location header — used to DELETE the session on teardown.
    }

    func publish(offerSDP: String) async throws -> Result {
        var req = URLRequest(url: URL(string: endpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/sdp", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(offerSDP.utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw WHIPError.badResponse }
        guard http.statusCode == 201 else {
            throw WHIPError.unexpectedStatus(http.statusCode, String(decoding: data, as: UTF8.self))
        }

        var resource: URL?
        if let location = http.value(forHTTPHeaderField: "Location") {
            resource = URL(string: location, relativeTo: URL(string: endpoint))
        }
        return Result(answerSDP: String(decoding: data, as: UTF8.self), resourceURL: resource)
    }

    func teardown(_ resource: URL) async {
        var req = URLRequest(url: resource)
        req.httpMethod = "DELETE"
        _ = try? await URLSession.shared.data(for: req)
    }
}

enum WHIPError: Error, CustomStringConvertible {
    case badResponse
    case unexpectedStatus(Int, String)

    var description: String {
        switch self {
        case .badResponse: return "WHIP: non-HTTP response"
        case .unexpectedStatus(let code, let body): return "WHIP: expected 201, got \(code): \(body)"
        }
    }
}
