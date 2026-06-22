import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

/// Captures a single display via ScreenCaptureKit and hands each frame's
/// CVPixelBuffer to a sink. ScreenCaptureKit delivers IOSurface-backed buffers
/// straight from the window server, so there is no CPU copy on the capture path.
final class ScreenCapturer: NSObject, SCStreamOutput {
    typealias FrameSink = (CVPixelBuffer, CMTime) -> Void

    private let config: StreamConfig
    private let sink: FrameSink
    private var stream: SCStream?
    private let sampleQueue = DispatchQueue(label: "ngx.screencapture.samples", qos: .userInteractive)

    init(config: StreamConfig, sink: @escaping FrameSink) {
        self.config = config
        self.sink = sink
    }

    func start() async throws {
        // Discovering shareable content also triggers the Screen Recording
        // permission prompt on first run.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        let displays = content.displays
        guard !displays.isEmpty else { throw CapturerError.noDisplays }
        guard config.displayIndex < displays.count else {
            throw CapturerError.badDisplayIndex(requested: config.displayIndex, available: displays.count)
        }
        let display = displays[config.displayIndex]

        // Capture the whole display, nothing excluded.
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let streamConfig = SCStreamConfiguration()
        streamConfig.width = display.width * 2   // capture at backing-store (Retina) resolution
        streamConfig.height = display.height * 2
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        streamConfig.queueDepth = 6
        streamConfig.showsCursor = config.showsCursor
        // BGRA maps directly to what VideoToolbox wants for the encoder.
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.colorSpaceName = CGColorSpace.sRGB

        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }

        // Drop frames the window server marks as not "complete" (e.g. idle/blank).
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let statusRaw = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRaw),
            status == .complete,
            let pixelBuffer = sampleBuffer.imageBuffer
        else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        sink(pixelBuffer, pts)
    }
}

enum CapturerError: Error, CustomStringConvertible {
    case noDisplays
    case badDisplayIndex(requested: Int, available: Int)

    var description: String {
        switch self {
        case .noDisplays:
            return "No capturable displays found."
        case .badDisplayIndex(let requested, let available):
            return "Display \(requested) does not exist (found \(available))."
        }
    }
}
