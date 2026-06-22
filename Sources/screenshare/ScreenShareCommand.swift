import ArgumentParser
import Foundation

/// `screenshare` — capture a macOS display with ScreenCaptureKit, encode with
/// VideoToolbox via libwebrtc, and publish over WHIP to Cloudflare Stream.
/// Viewers watch through a randomized public URL served by the Worker.
@main
struct ScreenShare: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshare",
        abstract: "Publish a hardware-encoded screen share to a public Cloudflare URL over WebRTC (WHIP/WHEP).",
        version: "0.1.0",
        subcommands: [Start.self],
        defaultSubcommand: Start.self
    )
}

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start capturing and go live."
    )

    @Option(name: .shortAndLong, help: "Display index to capture (0 = main display).")
    var display: Int = 0

    @Option(name: .shortAndLong, help: "Target capture frame rate.")
    var fps: Int = 60

    @Option(name: .shortAndLong, help: "Target video bitrate, e.g. 8M, 12000k, 6000000.")
    var bitrate: String = "8M"

    @Option(help: "Video codec preference.")
    var codec: VideoCodec = .h264

    @Option(help: "Base URL of your deployed Worker, e.g. https://screenshare.<you>.workers.dev. Overrides $SCREENSHARE_WORKER.")
    var worker: String?

    @Option(help: "Shared secret the Worker expects. Overrides $SCREENSHARE_TOKEN.")
    var token: String?

    @Flag(help: "Capture the cursor in the stream.")
    var showsCursor: Bool = false

    func run() async throws {
        let workerURL = try resolve(worker, env: "SCREENSHARE_WORKER", name: "--worker / $SCREENSHARE_WORKER")
        let authToken = try resolve(token, env: "SCREENSHARE_TOKEN", name: "--token / $SCREENSHARE_TOKEN")
        let bitrateBps = try parseBitrate(bitrate)

        let config = StreamConfig(
            displayIndex: display,
            fps: fps,
            bitrateBps: bitrateBps,
            codec: codec,
            showsCursor: showsCursor
        )

        let broker = SessionBroker(workerBaseURL: workerURL, token: authToken)
        let runner = StreamRunner(config: config, broker: broker)
        try await runner.start()
    }

    private func resolve(_ value: String?, env: String, name: String) throws -> String {
        if let v = value, !v.isEmpty { return v }
        if let v = ProcessInfo.processInfo.environment[env], !v.isEmpty { return v }
        throw ValidationError("Missing \(name).")
    }
}

enum VideoCodec: String, ExpressibleByArgument {
    case h264   // Universally HW-accelerated on Apple Silicon, best WebRTC interop.
    case h265   // Better compression; HW-encoded, but browser WHEP support is spottier.

    var sdpName: String {
        switch self {
        case .h264: return "H264"
        case .h265: return "H265"
        }
    }
}

/// Parse "8M", "8000k", or a raw bit count into bits per second.
func parseBitrate(_ s: String) throws -> Int {
    let lower = s.lowercased()
    if lower.hasSuffix("m"), let n = Double(lower.dropLast()) { return Int(n * 1_000_000) }
    if lower.hasSuffix("k"), let n = Double(lower.dropLast()) { return Int(n * 1_000) }
    if let n = Int(lower) { return n }
    throw ValidationError("Invalid bitrate: \(s)")
}

struct StreamConfig {
    let displayIndex: Int
    let fps: Int
    let bitrateBps: Int
    let codec: VideoCodec
    let showsCursor: Bool
}
