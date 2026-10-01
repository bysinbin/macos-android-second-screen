import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import IOSurface
import VirtualDisplayBridge

public final class TouchBarEngine: @unchecked Sendable {
    public static let shared = TouchBarEngine()
    
    public private(set) var isRunning: Bool = false
    public var onStatusChanged: (@Sendable (String) -> Void)?
    public var onClientConnected: (@Sendable () -> Void)?
    
    private var encoder: H264Encoder?
    private var server: NetworkServer?
    
    private var canvasBuffer: CVPixelBuffer?
    private var keepaliveTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.antigravity.touchbarengine", qos: .userInteractive)
    
    private var frameIndex: Int64 = 0
    private var lastDeliveredTime = Date()
    private let lock = NSLock()
    
    // Canvas dimensions (multiples of 16 for hardware H.264 encoders)
    public let canvasWidth: Int = 2016
    public let canvasHeight: Int = 128
    
    public init() {}
    
    public func start(port: UInt16 = ScreenProtocol.touchBarPort) throws {
        guard !isRunning else { return }
        guard VDBridgeTouchBarIsAvailable() else {
            throw NSError(domain: "TouchBarEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "macOS Touch Bar API bu sistemde desteklenmiyor."])
        }
        
        setupCanvasBuffer()
        
        let enc = H264Encoder(width: Int32(canvasWidth), height: Int32(canvasHeight), fps: 60, bitrate: 4_000_000)
        self.encoder = enc
        
        let netServer = NetworkServer(port: port, serviceType: ScreenProtocol.bonjourTouchBarType, serviceName: "MacTouchBarServer")
        self.server = netServer
        
        enc.onEncodedFrame = { [weak netServer] frameData in
            netServer?.broadcastFrame(frameData)
        }
        
        netServer.onClientConnected = { [weak enc, weak netServer, weak self] in
            if let cached = enc?.lastKeyframe {
                netServer?.broadcastFrame(cached)
            }
            enc?.requestKeyframe()
            self?.sendCurrentFrame()
            self?.onClientConnected?()
        }
        
        netServer.onTouchEvent = { [weak self] type, normX, normY, _ in
            self?.handleTouch(type: type, normX: normX, normY: normY)
        }
        
        try netServer.start(width: UInt32(canvasWidth), height: UInt32(canvasHeight), fps: 60)
        
        let started = VDBridgeTouchBarStart { [weak self] surface in
            self?.processSurface(surface)
        }
        
        guard started else {
            netServer.stop()
            self.server = nil
            self.encoder = nil
            throw NSError(domain: "TouchBarEngine", code: 2, userInfo: [NSLocalizedDescriptionKey: "Touch Bar akışı başlatılamadı."])
        }
        
        startKeepalive()
        self.isRunning = true
        onStatusChanged?("🪄 Touch Bar Yayında (Port \(port))")
    }
    
    private func setupCanvasBuffer() {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: canvasWidth,
            kCVPixelBufferHeightKey: canvasHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, canvasWidth, canvasHeight, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &canvasBuffer)
        
        if let buf = canvasBuffer {
            CVPixelBufferLockBaseAddress(buf, [])
            if let base = CVPixelBufferGetBaseAddress(buf) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(buf)
                memset(base, 0, bytesPerRow * canvasHeight)
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
        }
    }
    
    private func processSurface(_ surface: IOSurfaceRef) {
        nonisolated(unsafe) let unsafeSurface = surface
        queue.async { [weak self] in
            guard let self = self, let canvas = self.canvasBuffer else { return }
            
            let sw = IOSurfaceGetWidth(unsafeSurface)
            let sh = IOSurfaceGetHeight(unsafeSurface)
            
            IOSurfaceLock(unsafeSurface, .readOnly, nil)
            CVPixelBufferLockBaseAddress(canvas, [])
            
            let srcBase = IOSurfaceGetBaseAddress(unsafeSurface)
            if let dstBase = CVPixelBufferGetBaseAddress(canvas) {
                let srcStride = IOSurfaceGetBytesPerRow(unsafeSurface)
                let dstStride = CVPixelBufferGetBytesPerRow(canvas)
                
                let offsetY = max(0, (self.canvasHeight - sh) / 2)
                let offsetX = max(0, (self.canvasWidth - sw) / 2) * 4
                let copyBytes = min(sw, self.canvasWidth) * 4
                let copyRows = min(sh, self.canvasHeight)
                
                for row in 0..<copyRows {
                    let s = srcBase.advanced(by: row * srcStride)
                    let d = dstBase.advanced(by: (row + offsetY) * dstStride + offsetX)
                    memcpy(d, s, copyBytes)
                }
            }
            
            CVPixelBufferUnlockBaseAddress(canvas, [])
            IOSurfaceUnlock(unsafeSurface, .readOnly, nil)
            
            self.lock.lock()
            self.lastDeliveredTime = Date()
            let pts = CMTime(value: self.frameIndex, timescale: 60)
            self.frameIndex += 1
            self.lock.unlock()
            
            self.encoder?.encode(pixelBuffer: canvas, presentationTime: pts)
        }
    }
    
    private func sendCurrentFrame() {
        queue.async { [weak self] in
            guard let self = self, let canvas = self.canvasBuffer else { return }
            self.lock.lock()
            self.lastDeliveredTime = Date()
            let pts = CMTime(value: self.frameIndex, timescale: 60)
            self.frameIndex += 1
            self.lock.unlock()
            self.encoder?.encode(pixelBuffer: canvas, presentationTime: pts)
        }
    }
    
    private func startKeepalive() {
        keepaliveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(33), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let now = Date()
            self.lock.lock()
            let elapsed = now.timeIntervalSince(self.lastDeliveredTime)
            if elapsed >= 0.030, let canvas = self.canvasBuffer {
                self.lastDeliveredTime = now
                let pts = CMTime(value: self.frameIndex, timescale: 60)
                self.frameIndex += 1
                self.lock.unlock()
                self.encoder?.encode(pixelBuffer: canvas, presentationTime: pts)
            } else {
                self.lock.unlock()
            }
        }
        timer.resume()
        self.keepaliveTimer = timer
    }
    
    private func handleTouch(type: UInt8, normX: Float, normY: Float) {
        let sw = 2008.0
        let sh = 60.0
        let offsetX = Double(canvasWidth - Int(sw)) / 2.0
        let offsetY = Double(canvasHeight - Int(sh)) / 2.0
        
        let canvasPixelX = Double(normX) * Double(canvasWidth)
        let canvasPixelY = Double(normY) * Double(canvasHeight)
        
        let tbPixelX = max(0.0, min(sw, canvasPixelX - offsetX))
        let tbPixelY = max(0.0, min(sh, canvasPixelY - offsetY))
        
        let tbNormX = Float(tbPixelX / sw)
        let tbNormY = Float(tbPixelY / sh)
        
        VDBridgeTouchBarPostEvent(type, tbNormX, tbNormY)
    }
    
    public func stop() {
        guard isRunning else { return }
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        
        VDBridgeTouchBarStop()
        server?.stop()
        server = nil
        encoder?.invalidate()
        encoder = nil
        canvasBuffer = nil
        
        isRunning = false
        onStatusChanged?("⏹️ Touch Bar Durduruldu")
    }
}
