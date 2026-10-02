import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import VirtualDisplayBridge

// MARK: - Display Server Instance (Represents 1 Display Stream)

public final class DisplayServerInstance: @unchecked Sendable, ScreenCapturerDelegate, Identifiable {
    public let id: UUID
    public var name: String
    public var port: UInt16
    public private(set) var displayID: CGDirectDisplayID = 0
    public private(set) var isMirrorMode: Bool = false
    public private(set) var width: UInt32 = 1920
    public private(set) var height: UInt32 = 1080
    public private(set) var fps: UInt32 = 60
    public private(set) var bitrateMbps: Int32 = 10
    
    private var capturer: ScreenCapturer?
    private var encoder: H264Encoder?
    private var server: NetworkServer?
    private var touchInjector: TouchInjector?
    
    public private(set) var isRunning: Bool = false
    public var onClientConnected: (@Sendable () -> Void)?
    public var onStatusChanged: (@Sendable (String) -> Void)?
    
    public init(id: UUID = UUID(), name: String, port: UInt16) {
        self.id = id
        self.name = name
        self.port = port
    }
    
    public func start(isMirror: Bool, width: UInt32, height: UInt32, fps: UInt32 = 60, bitrateMbps: Int32 = 10) async throws {
        if isRunning {
            await stop()
        }
        
        self.isMirrorMode = isMirror
        self.fps = fps
        self.bitrateMbps = bitrateMbps
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
            onStatusChanged?("🪞 \(name) Yansıtma Modu Aktif (\(actualWidth)x\(actualHeight))")
        } else {
            let createdID = VDBridgeCreateDisplay(name, actualWidth, actualHeight, Double(fps), false)
            guard createdID != 0 else {
                throw NSError(domain: "DisplayServerInstance", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(name) sanal ekranı oluşturulamadı."])
            }
            self.displayID = createdID
            onStatusChanged?("🖥️ \(name) Aktif (\(actualWidth)x\(actualHeight), Port \(port))")
        }
        
        self.width = actualWidth
        self.height = actualHeight
        
        try? await Task.sleep(nanoseconds: 600_000_000)
        
        let touch = TouchInjector(displayID: displayID)
        self.touchInjector = touch
        
        let enc = H264Encoder(width: Int32(actualWidth), height: Int32(actualHeight), fps: Int32(fps), bitrate: bitrateMbps * 1_000_000)
        self.encoder = enc
        
        let netServer = NetworkServer(port: port, serviceType: ScreenProtocol.bonjourServiceType, serviceName: name)
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
        if !isMirrorMode && displayID != 0 {
            VDBridgeDestroyDisplayByID(displayID)
        }
        displayID = 0
        isRunning = false
        onStatusChanged?("⏹️ \(name) Durduruldu")
    }
    
    public func didCaptureFrame(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        encoder?.encode(pixelBuffer: pixelBuffer, presentationTime: presentationTime)
    }
}

// MARK: - Screen Server Manager (Multi-Display Coordinator)

public final class ScreenServerManager: @unchecked Sendable {
    public static let shared = ScreenServerManager()
    
    private let lock = NSLock()
    public private(set) var servers: [DisplayServerInstance] = []
    
    public init() {
        // Pre-create Default Primary Screen on Port 8888
        let primary = DisplayServerInstance(name: "Mac Ekran 1", port: ScreenProtocol.defaultPort)
        servers.append(primary)
    }
    
    public var defaultServer: DisplayServerInstance {
        lock.lock()
        defer { lock.unlock() }
        if servers.isEmpty {
            let primary = DisplayServerInstance(name: "Mac Ekran 1", port: ScreenProtocol.defaultPort)
            servers.append(primary)
            return primary
        }
        return servers[0]
    }
    
    public func addServer(name: String? = nil, port: UInt16? = nil) -> DisplayServerInstance {
        lock.lock()
        defer { lock.unlock() }
        
        let index = servers.count + 1
        let defaultPort: UInt16 = UInt16(8888 + (servers.count * 2)) // 8888, 8890, 8892... (8889 is TouchBar)
        let resolvedPort = port ?? (defaultPort == ScreenProtocol.touchBarPort ? defaultPort + 1 : defaultPort)
        let serverName = name ?? "Mac Ekran \(index)"
        
        let instance = DisplayServerInstance(name: serverName, port: resolvedPort)
        servers.append(instance)
        return instance
    }
    
    private func getServersSnapshot() -> [DisplayServerInstance] {
        lock.withLock { servers }
    }
    
    private func popServer(id: UUID) -> DisplayServerInstance? {
        lock.withLock {
            if let idx = servers.firstIndex(where: { $0.id == id }), servers.count > 1 {
                return servers.remove(at: idx)
            }
            return nil
        }
    }

    public func removeServer(id: UUID) async {
        let serverToStop = popServer(id: id)
        await serverToStop?.stop()
    }
    
    public func stopAll() async {
        let list = getServersSnapshot()
        for s in list {
            await s.stop()
        }
        VDBridgeDestroyAllDisplays()
    }
}

// MARK: - Backward Compatibility Facade: ScreenEngine

public final class ScreenEngine: @unchecked Sendable {
    public static let shared = ScreenEngine()
    
    public var isRunning: Bool {
        ScreenServerManager.shared.defaultServer.isRunning
    }
    
    public var onClientConnected: (@Sendable () -> Void)? {
        get { ScreenServerManager.shared.defaultServer.onClientConnected }
        set { ScreenServerManager.shared.defaultServer.onClientConnected = newValue }
    }
    
    public var onStatusChanged: (@Sendable (String) -> Void)? {
        get { ScreenServerManager.shared.defaultServer.onStatusChanged }
        set { ScreenServerManager.shared.defaultServer.onStatusChanged = newValue }
    }
    
    public func start(isMirror: Bool, width: UInt32, height: UInt32, fps: UInt32 = 60, bitrateMbps: Int32 = 10, port: UInt16 = ScreenProtocol.defaultPort) async throws {
        let server = ScreenServerManager.shared.defaultServer
        server.port = port
        try await server.start(isMirror: isMirror, width: width, height: height, fps: fps, bitrateMbps: bitrateMbps)
    }
    
    public func stop() async {
        await ScreenServerManager.shared.defaultServer.stop()
    }
}
