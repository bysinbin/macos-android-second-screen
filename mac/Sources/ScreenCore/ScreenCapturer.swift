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
    private let captureQueue = DispatchQueue(label: "com.antigravity.screencapture", qos: .userInteractive)
    private var idleTimer: DispatchSourceTimer?
    private var lastCaptureTimestamp = Date()
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
        
        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await newStream.startCapture()
        self.stream = newStream
        self.lastCaptureTimestamp = Date()
        print("[ScreenCapturer] Screen capture started for display ID \(displayID) (\(width)x\(height) @ \(fps)fps)")
        
        // Kickstart the display with initial cursor position
        kickstart()
        startIdleHeartbeat()
    }
    
    public func kickstart() {
        let bounds = CGDisplayBounds(self.displayID)
        guard bounds.width > 0 && bounds.height > 0 else { return }
        let cur = CGEvent(source: nil)?.location ?? CGPoint(x: bounds.midX, y: bounds.midY)
        if bounds.contains(cur) {
            CGWarpMouseCursorPosition(CGPoint(x: cur.x + 1, y: cur.y))
            usleep(2000)
            CGWarpMouseCursorPosition(cur)
        } else {
            CGWarpMouseCursorPosition(CGPoint(x: bounds.midX, y: bounds.midY))
        }
    }
    
    private func startIdleHeartbeat() {
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            if Date().timeIntervalSince(self.lastCaptureTimestamp) >= 1.0 {
                self.kickstart()
            }
        }
        timer.resume()
        self.idleTimer = timer
    }
    
    public func stop() async {
        idleTimer?.cancel()
        idleTimer = nil
        
        if let stream = stream {
            do {
                try await stream.stopCapture()
            } catch {
                print("[ScreenCapturer] Error stopping capture: \(error)")
            }
            self.stream = nil
        }
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
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        delegate?.didCaptureFrame(pixelBuffer, presentationTime: presentationTime)
    }
    
    // MARK: - SCStreamDelegate
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[ScreenCapturer] Stream stopped with error: \(error)")
    }
}
