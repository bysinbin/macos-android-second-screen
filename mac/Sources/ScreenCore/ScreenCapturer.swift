import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo

public protocol ScreenCapturerDelegate: AnyObject, Sendable {
    func didCaptureFrame(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime)
}

public final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let displayID: CGDirectDisplayID
    private let width: Int
    private let height: Int
    private let fps: Int
    
    private var stream: SCStream?
    private var filter: SCContentFilter?
    private var config: SCStreamConfiguration?
    private let captureQueue = DispatchQueue(label: "com.antigravity.screencapture", qos: .userInteractive)
    private var lastCaptureTimestamp = Date()
    private var lastPixelBuffer: CVPixelBuffer?
    private var frameIndex: Int64 = 0
    private var keepaliveTimer: DispatchSourceTimer?
    public weak var delegate: ScreenCapturerDelegate?
    
    public init(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int = 60) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.fps = fps
        super.init()
    }
    
    public func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let targetDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "ScreenCapturer", code: 404, userInfo: [NSLocalizedDescriptionKey: "Display ID \(displayID) not found in shareable content."])
        }
        
        let filter = SCContentFilter(display: targetDisplay, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.capturesAudio = false
        
        self.filter = filter
        self.config = config
        
        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await newStream.startCapture()
        self.stream = newStream
        self.lastCaptureTimestamp = Date()
        print("[ScreenCapturer] Screen capture started for display ID \(displayID) (\(width)x\(height) @ \(fps)fps)")
        
        // Capture initial frame immediately without touching the cursor
        triggerImmediateCapture()
        startKeepalive()
    }
    
    public func kickstart() {
        triggerImmediateCapture()
    }
    
    private func triggerImmediateCapture() {
        guard let filter = self.filter, let config = self.config else { return }
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let sample = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config)
                guard sample.isValid,
                      let imageBuffer = sample.imageBuffer,
                      CFGetTypeID(imageBuffer) == CVPixelBufferGetTypeID() else {
                    return
                }
                self.lastCaptureTimestamp = Date()
                let pixelBuffer = imageBuffer as CVPixelBuffer
                self.lastPixelBuffer = pixelBuffer
                let pts = CMTime(value: self.frameIndex, timescale: CMTimeScale(self.fps))
                self.frameIndex += 1
                self.delegate?.didCaptureFrame(pixelBuffer, presentationTime: pts)
            } catch {
                // Silently ignore if busy or not ready
            }
        }
    }
    
    private func startKeepalive() {
        keepaliveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        let intervalMs = max(10, 1000 / fps)
        timer.schedule(deadline: .now() + .milliseconds(intervalMs), repeating: .milliseconds(intervalMs))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let elapsed = Date().timeIntervalSince(self.lastCaptureTimestamp)
            // If display produced no new frame for >= 1.5 frame intervals, re-inject last buffer
            if elapsed >= (Double(intervalMs) * 1.4 / 1000.0), let buffer = self.lastPixelBuffer {
                self.lastCaptureTimestamp = Date()
                let pts = CMTime(value: self.frameIndex, timescale: CMTimeScale(self.fps))
                self.frameIndex += 1
                self.delegate?.didCaptureFrame(buffer, presentationTime: pts)
            }
        }
        timer.resume()
        self.keepaliveTimer = timer
    }
    
    public func stop() async {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        lastPixelBuffer = nil
        
        if let stream = stream {
            do {
                try await stream.stopCapture()
            } catch {
                print("[ScreenCapturer] Error stopping capture: \(error)")
            }
            self.stream = nil
        }
        self.filter = nil
        self.config = nil
    }
    
    // MARK: - SCStreamOutput
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              sampleBuffer.isValid,
              let imageBuffer = sampleBuffer.imageBuffer,
              CFGetTypeID(imageBuffer) == CVPixelBufferGetTypeID() else {
            return
        }
        
        self.lastCaptureTimestamp = Date()
        let pixelBuffer = imageBuffer as CVPixelBuffer
        self.lastPixelBuffer = pixelBuffer
        let pts = CMTime(value: frameIndex, timescale: CMTimeScale(fps))
        frameIndex += 1
        delegate?.didCaptureFrame(pixelBuffer, presentationTime: pts)
    }
    
    // MARK: - SCStreamDelegate
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[ScreenCapturer] Stream stopped with error: \(error)")
    }
}
