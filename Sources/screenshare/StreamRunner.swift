import Foundation

/// Orchestrates one publishing session end to end:
///   1. ask the Worker for a room (WHIP URL + public viewer URL)
///   2. start ScreenCaptureKit, feeding frames to the WebRTC encoder
///   3. negotiate over WHIP, then idle until interrupted
final class StreamRunner {
    private let config: StreamConfig
    private let broker: SessionBroker
    private let publisher: WebRTCPublisher
    private var capturer: ScreenCapturer!
    private var whipResource: URL?
    private var whipEndpoint: String?

    init(config: StreamConfig, broker: SessionBroker) {
        self.config = config
        self.broker = broker
        self.publisher = WebRTCPublisher(config: config)
    }

    func start() async throws {
        log("Requesting session from Worker…")
        let session = try await broker.createSession()
        self.whipEndpoint = session.whipUrl

        capturer = ScreenCapturer(config: config) { [weak self] pixelBuffer, pts in
            self?.publisher.push(pixelBuffer: pixelBuffer, pts: pts)
        }

        log("Starting capture (display \(config.displayIndex), \(config.fps)fps, \(config.codec.rawValue.uppercased()), \(config.bitrateBps / 1_000_000)Mbps)…")
        try await capturer.start()

        log("Negotiating WHIP with Cloudflare…")
        let offer = try await publisher.makeOffer()
        let whip = WHIPClient(endpoint: session.whipUrl)
        let result = try await whip.publish(offerSDP: offer)
        self.whipResource = result.resourceURL
        try await publisher.acceptAnswer(result.answerSDP)

        printBanner(viewerURL: session.viewerUrl, roomId: session.roomId)
        installSignalHandlers()

        // Idle forever; teardown happens in the signal handler.
        try await Task.sleep(nanoseconds: .max)
    }

    private func shutdown() async {
        log("Shutting down…")
        await capturer?.stop()
        if let resource = whipResource {
            await WHIPClient(endpoint: whipEndpoint ?? "").teardown(resource)
        }
        publisher.close()
    }

    private func installSignalHandlers() {
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signal(SIGINT, SIG_IGN)
        source.setEventHandler {
            Task {
                await self.shutdown()
                Foundation.exit(0)
            }
        }
        source.resume()
        // Keep the source alive for the process lifetime.
        Self.signalSource = source
    }

    private static var signalSource: DispatchSourceSignal?

    private func printBanner(viewerURL: String, roomId: String) {
        let line = String(repeating: "─", count: 60)
        print("""

        \(line)
          🔴  LIVE — share this URL:

              \(viewerURL)

          room: \(roomId)   ·   press Ctrl-C to stop
        \(line)

        """)
    }

    private func log(_ msg: String) {
        FileHandle.standardError.write(Data("[screenshare] \(msg)\n".utf8))
    }
}
