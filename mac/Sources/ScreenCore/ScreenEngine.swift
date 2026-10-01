import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import VirtualDisplayBridge

public final class ScreenEngine: @unchecked Sendable, ScreenCapturerDelegate {
    public static let shared = ScreenEngine()
    
    private var displayID: CGDirectDisplayID = 0
    private var isMirrorMode: Bool = false
    private var capturer: ScreenCapturer?
    private var encoder: H264Encoder?
    private var server: NetworkServer?
    private var touchInjector: TouchInjector?
    
    public private(set) var isRunning: Bool = false
    public var onClientConnected: (@Sendable () -> Void)?
    public var onStatusChanged: (@Sendable (String) -> Void)?
    
    public init() {}
    
    public func start(isMirror: Bool, width: UInt32, height: UInt32, fps: UInt32 = 60, bitrateMbps: Int32 = 10, port: UInt16 = ScreenProtocol.defaultPort) async throws {
        if isRunning {
            await stop()
        }
        
        self.isMirrorMode = isMirror
        var actualWidth = width
        var actualHeight = height
        
        if isMirror {
            let mainID = CGMainDisplayID()
            let mainBounds = CGDisplayBounds(mainID)
            let aspect = mainBounds.width / mainBounds.height
            actualWidth = 1920
            var calcH = UInt32(round(1920.0 / aspect))
            if calcH % 2 != 0 { calcH += 1 }
            actualHeight = calcH
            self.displayID = mainID
            onStatusChanged?("🪞 Yansıtma Modu Aktif (\(actualWidth)x\(actualHeight))")
        } else {
            let createdID = VDBridgeCreateDisplay("Android Display", actualWidth, actualHeight, Double(fps), false)
            guard createdID != 0 else {
                throw NSError(domain: "ScreenEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Sanal ekran oluşturulamadı."])
            }
            self.displayID = createdID
            onStatusChanged?("🖥️ 2. Ekran Aktif (\(actualWidth)x\(actualHeight))")
        }
        
        try? await Task.sleep(nanoseconds: 600_000_000)
        
        let touch = TouchInjector(displayID: displayID)
        self.touchInjector = touch
        
        let enc = H264Encoder(width: Int32(actualWidth), height: Int32(actualHeight), fps: Int32(fps), bitrate: bitrateMbps * 1_000_000)
        self.encoder = enc
        
        let netServer = NetworkServer(port: port)
        self.server = netServer
        
        let screenCap = ScreenCapturer(displayID: displayID, width: Int(actualWidth), height: Int(actualHeight), fps: Int(fps))
        screenCap.delegate = self
        self.capturer = screenCap
        
        enc.onEncodedFrame = { [weak netServer] frameData in
            netServer?.broadcastFrame(frameData)
        }
        
        netServer.onClientConnected = { [weak enc, weak screenCap, weak netServer, weak self] in
            if let cached = enc?.lastKeyframe {
                netServer?.broadcastFrame(cached)
            }
            enc?.requestKeyframe()
            screenCap?.kickstart()
            self?.onClientConnected?()
        }
        
        netServer.onTouchEvent = { [weak touch] type, x, y, dy in
            touch?.handleTouchEvent(type: type, normX: x, normY: y, deltaY: dy)
        }
        
        try netServer.start(width: actualWidth, height: actualHeight, fps: fps)
        
        try await screenCap.start()
        self.isRunning = true
    }
    
    public func stop() async {
        guard isRunning else { return }
        server?.stop()
        server = nil
        encoder?.invalidate()
        encoder = nil
        await capturer?.stop()
        capturer = nil
        if !isMirrorMode {
            VDBridgeDestroyDisplay()
        }
        displayID = 0
        isRunning = false
        onStatusChanged?("⏹️ Sunucu Durduruldu")
    }
    
    public func didCaptureFrame(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        encoder?.encode(pixelBuffer: pixelBuffer, presentationTime: presentationTime)
    }
}
