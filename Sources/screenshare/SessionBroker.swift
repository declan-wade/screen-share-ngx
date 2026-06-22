import Foundation

/// A live session minted by the Worker.
struct Session: Decodable {
    let roomId: String      // random, unguessable room slug
    let whipUrl: String     // Cloudflare Stream WHIP ingest endpoint (contains its own secret)
    let viewerUrl: String   // public page served by the Worker (WHEP player)
}

enum BrokerError: Error, CustomStringConvertible {
    case http(Int, String)
    case decode(String)

    var description: String {
        switch self {
        case .http(let code, let body): return "Worker returned HTTP \(code): \(body)"
        case .decode(let msg): return "Could not decode Worker response: \(msg)"
        }
    }
}

/// Talks to the Cloudflare Worker, which holds the Stream API token and creates
/// a Live Input on our behalf. The CLI never sees the Cloudflare account token —
/// only the per-session WHIP URL it needs to publish.
struct SessionBroker {
    let workerBaseURL: String
    let token: String

    func createSession() async throws -> Session {
        var req = URLRequest(url: URL(string: workerBaseURL.trimmingTrailingSlash() + "/api/sessions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("{}".utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw BrokerError.decode("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BrokerError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        do {
            return try JSONDecoder().decode(Session.self, from: data)
        } catch {
            throw BrokerError.decode("\(error)")
        }
    }
}

private extension String {
    func trimmingTrailingSlash() -> String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}
