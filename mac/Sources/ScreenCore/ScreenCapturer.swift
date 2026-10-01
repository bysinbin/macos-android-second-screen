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
    
    // Private buffer pool for deep copies (never starves ScreenCaptureKit's internal pool)
    // All buffer access is serialized on captureQueue
    private var privateBufferPool: CVPixelBufferPool?
    private var latestPixelBuffer: CVPixelBuffer?
    private var keepaliveTimer: DispatchSourceTimer?
    private var frameIndex: Int64 = 0
    private var lastDeliveredTimestamp = Date()
    
    public weak var delegate: ScreenCapturerDelegate?
    
    public init(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int = 60) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.fps = fps
        super.init()
    }
    
    public func start() async throws {
        setupBufferPool()
        
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
        self.lastDeliveredTimestamp = Date()
        print("[ScreenCapturer] Screen capture started for display ID \(displayID) (\(width)x\(height) @ \(fps)fps)")
        
        startKeepalive()
        triggerImmediateCapture()
    }
    
    private func setupBufferPool() {
        let bufferAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]
        ]
        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 3
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, bufferAttrs as CFDictionary, &privateBufferPool)
    }
    
    private func copyBuffer(from src: CVPixelBuffer) -> CVPixelBuffer? {
        guard let pool = privateBufferPool else { return nil }
        var dst: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dst)
        guard status == kCVReturnSuccess, let dest = dst else { return nil }
        
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dest, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dest, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        
        let planeCount = CVPixelBufferGetPlaneCount(src)
        if planeCount > 0 {
            for plane in 0..<planeCount {
                guard let s = CVPixelBufferGetBaseAddressOfPlane(src, plane),
                      let d = CVPixelBufferGetBaseAddressOfPlane(dest, plane) else { continue }
                let sStride = CVPixelBufferGetBytesPerRowOfPlane(src, plane)
                let dStride = CVPixelBufferGetBytesPerRowOfPlane(dest, plane)
                let h = CVPixelBufferGetHeightOfPlane(src, plane)
                if sStride == dStride {
                    memcpy(d, s, sStride * h)
                } else {
                    let w = min(sStride, dStride)
                    for r in 0..<h {
                        memcpy(d.advanced(by: r * dStride), s.advanced(by: r * sStride), w)
                    }
                }
            }
        } else {
            guard let s = CVPixelBufferGetBaseAddress(src),
                  let d = CVPixelBufferGetBaseAddress(dest) else { return dest }
            let sStride = CVPixelBufferGetBytesPerRow(src)
            let dStride = CVPixelBufferGetBytesPerRow(dest)
            let h = CVPixelBufferGetHeight(src)
            if sStride == dStride {
                memcpy(d, s, sStride * h)
            } else {
                let w = min(sStride, dStride)
                for r in 0..<h {
                    memcpy(d.advanced(by: r * dStride), s.advanced(by: r * sStride), w)
                }
            }
        }
        return dest
    }
    
    private func startKeepalive() {
        keepaliveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        // 30 FPS minimum keepalive (every ~33ms)
        let intervalMs = 33
        timer.schedule(deadline: .now() + .milliseconds(intervalMs), repeating: .milliseconds(intervalMs))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let now = Date()
            let elapsed = now.timeIntervalSince(self.lastDeliveredTimestamp)
            // If macOS hasn't sent a new frame for >= 30ms, re-transmit copied buffer
            if elapsed >= 0.030, let buffer = self.latestPixelBuffer {
                self.lastDeliveredTimestamp = now
                let pts = CMTime(value: self.frameIndex, timescale: CMTimeScale(self.fps))
                self.frameIndex += 1
                self.delegate?.didCaptureFrame(buffer, presentationTime: pts)
            }
        }
        timer.resume()
        self.keepaliveTimer = timer
    }
    
    public func kickstart() {
        captureQueue.async { [weak self] in
            guard let self = self else { return }
            if let buffer = self.latestPixelBuffer {
                let pts = CMTime(value: self.frameIndex, timescale: CMTimeScale(self.fps))
                self.frameIndex += 1
                self.delegate?.didCaptureFrame(buffer, presentationTime: pts)
            }
        }
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
                let pixelBuffer = imageBuffer as CVPixelBuffer
                nonisolated(unsafe) let unsafeBuffer = pixelBuffer
                self.captureQueue.async {
                    if let copied = self.copyBuffer(from: unsafeBuffer) {
                        self.latestPixelBuffer = copied
                        self.lastDeliveredTimestamp = Date()
                        let pts = CMTime(value: self.frameIndex, timescale: CMTimeScale(self.fps))
                        self.frameIndex += 1
                        self.delegate?.didCaptureFrame(copied, presentationTime: pts)
                    }
                }
            } catch {
                // Silently ignore if busy or not ready
            }
        }
    }
    
    public func stop() async {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                self?.keepaliveTimer?.cancel()
                self?.keepaliveTimer = nil
                self?.latestPixelBuffer = nil
                self?.privateBufferPool = nil
                continuation.resume()
            }
        }
        
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
        
        let pixelBuffer = imageBuffer as CVPixelBuffer
        // Deep copy into our private buffer so ScreenCaptureKit's internal 5-buffer pool is NEVER retained/starved
        if let copied = copyBuffer(from: pixelBuffer) {
            latestPixelBuffer = copied
            lastDeliveredTimestamp = Date()
            let pts = CMTime(value: frameIndex, timescale: CMTimeScale(fps))
            frameIndex += 1
            
            delegate?.didCaptureFrame(copied, presentationTime: pts)
        }
    }
    
    // MARK: - SCStreamDelegate
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[ScreenCapturer] Stream stopped with error: \(error)")
    }
}

