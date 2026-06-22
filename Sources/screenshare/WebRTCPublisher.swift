import Foundation
import WebRTC
import CoreVideo
import CoreMedia

/// Wraps a libwebrtc PeerConnection configured as a send-only video publisher.
/// The default encoder factory uses VideoToolbox on Apple platforms, so frames
/// are hardware-encoded (H.264 or HEVC) with no extra wiring.
final class WebRTCPublisher: NSObject, RTCPeerConnectionDelegate, @unchecked Sendable {

    private let config: StreamConfig
    private let factory: RTCPeerConnectionFactory
    private let videoSource: RTCVideoSource
    private let videoTrack: RTCVideoTrack
    private let capturer: RTCVideoCapturer   // a stub; we push frames manually
    private var pc: RTCPeerConnection!
    private var sender: RTCRtpSender?

    private var iceGatheringComplete: CheckedContinuation<Void, Never>?

    init(config: StreamConfig) {
        self.config = config

        RTCInitializeSSL()
        let encoder = RTCDefaultVideoEncoderFactory()   // includes VideoToolbox H264/H265
        let decoder = RTCDefaultVideoDecoderFactory()
        self.factory = RTCPeerConnectionFactory(encoderFactory: encoder, decoderFactory: decoder)

        self.videoSource = factory.videoSource()
        self.videoTrack = factory.videoTrack(with: videoSource, trackId: "screen0")
        self.capturer = RTCVideoCapturer(delegate: videoSource)
        super.init()
    }

    /// Hand a captured frame to the encoder. Called on the capture queue.
    func push(pixelBuffer: CVPixelBuffer, pts: CMTime) {
        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let timestampNs = Int64(CMTimeGetSeconds(pts) * Double(NSEC_PER_SEC))
        let frame = RTCVideoFrame(buffer: rtcBuffer, rotation: ._0, timeStampNs: timestampNs)
        videoSource.capturer(capturer, didCapture: frame)
    }

    /// Build the offer SDP to send to the WHIP endpoint.
    func makeOffer() async throws -> String {
        let rtcConfig = RTCConfiguration()
        rtcConfig.sdpSemantics = .unifiedPlan
        // Cloudflare's WHIP endpoint provides ICE in its answer; a public STUN
        // server helps surface server-reflexive candidates quickly.
        rtcConfig.iceServers = [RTCIceServer(urlStrings: ["stun:stun.cloudflare.com:3478"])]
        rtcConfig.bundlePolicy = .maxBundle
        rtcConfig.continualGatheringPolicy = .gatherOnce

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: rtcConfig, constraints: constraints, delegate: self) else {
            throw PublisherError.peerConnectionFailed
        }
        self.pc = pc

        let transceiver = pc.addTransceiver(with: videoTrack,
                                            init: transceiverInit(direction: .sendOnly))
        self.sender = transceiver?.sender
        applyCodecPreference(to: transceiver)
        applyBitrate()

        let offer = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<RTCSessionDescription, Error>) in
            pc.offer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { sdp, err in
                if let err = err { cont.resume(throwing: err) }
                else if let sdp = sdp { cont.resume(returning: sdp) }
                else { cont.resume(throwing: PublisherError.noOffer) }
            }
        }

        try await setLocal(offer)
        // Wait for ICE gathering so the offer we POST is complete (Cloudflare
        // WHIP does not require trickle).
        await waitForIceGathering()
        return pc.localDescription?.sdp ?? offer.sdp
    }

    /// Apply the SDP answer returned by the WHIP server.
    func acceptAnswer(_ sdp: String) async throws {
        let answer = RTCSessionDescription(type: .answer, sdp: sdp)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(answer) { err in
                if let err = err { cont.resume(throwing: err) } else { cont.resume() }
            }
        }
    }

    func close() {
        pc?.close()
        RTCCleanupSSL()
    }

    // MARK: - Helpers

    private func transceiverInit(direction: RTCRtpTransceiverDirection) -> RTCRtpTransceiverInit {
        let initObj = RTCRtpTransceiverInit()
        initObj.direction = direction
        return initObj
    }

    /// Move the preferred codec to the front of the transceiver's codec list.
    private func applyCodecPreference(to transceiver: RTCRtpTransceiver?) {
        guard let transceiver else { return }
        let wanted = config.codec.sdpName
        let caps = factory.rtpSenderCapabilities(forKind: "video")
        let preferred = caps.codecs.filter { $0.name.uppercased() == wanted }
        let rest = caps.codecs.filter { $0.name.uppercased() != wanted }
        guard !preferred.isEmpty else { return }
        // The throwing setCodecPreferences:error: variant isn't exposed in this
        // libwebrtc build; the non-throwing overload is deprecated but functional.
        transceiver.setCodecPreferences(preferred + rest)
    }

    private func applyBitrate() {
        guard let sender else { return }
        let params = sender.parameters
        for encoding in params.encodings {
            encoding.maxBitrateBps = NSNumber(value: config.bitrateBps)
            encoding.maxFramerate = NSNumber(value: config.fps)
        }
        sender.parameters = params
    }

    private func setLocal(_ sdp: RTCSessionDescription) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(sdp) { err in
                if let err = err { cont.resume(throwing: err) } else { cont.resume() }
            }
        }
    }

    private func waitForIceGathering() async {
        if pc.iceGatheringState == .complete { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            self.iceGatheringComplete = cont
            // Safety timeout: don't block forever on a stalled candidate.
            DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self, let c = self.iceGatheringComplete else { return }
                self.iceGatheringComplete = nil
                c.resume()
            }
        }
    }

    // MARK: RTCPeerConnectionDelegate

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete, let c = iceGatheringComplete {
            iceGatheringComplete = nil
            c.resume()
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        FileHandle.standardError.write(Data("ICE: \(newState.rawValue)\n".utf8))
    }

    // Unused delegate callbacks (required by protocol).
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

enum PublisherError: Error {
    case peerConnectionFailed
    case noOffer
}
