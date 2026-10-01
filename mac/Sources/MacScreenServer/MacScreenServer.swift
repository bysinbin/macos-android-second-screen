import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import VirtualDisplayBridge

@main
final class MacScreenServerApp: @unchecked Sendable, ScreenCapturerDelegate {
    private var displayID: CGDirectDisplayID = 0
    private var capturer: ScreenCapturer?
    private var encoder: H264Encoder?
    private var server: NetworkServer?
    private var touchInjector: TouchInjector?
    
    static func main() async {
        let app = MacScreenServerApp()
        await app.run()
    }
    
    func run() async {
        printBanner()
        
        var width: UInt32 = 1640
        var height: UInt32 = 720
        var fps: UInt32 = 60
        var bitrateMbps: Int32 = 6
        var port: UInt16 = ScreenProtocol.defaultPort
        
        let args = CommandLine.arguments
        for i in 1..<args.count {
            if args[i] == "--portrait" {
                width = 720
                height = 1640
            } else if args[i] == "--landscape" {
                width = 1640
                height = 720
            } else if args[i] == "--width", i + 1 < args.count, let val = UInt32(args[i+1]) {
                width = val
            } else if args[i] == "--height", i + 1 < args.count, let val = UInt32(args[i+1]) {
                height = val
            } else if args[i] == "--fps", i + 1 < args.count, let val = UInt32(args[i+1]) {
                fps = val
            } else if args[i] == "--bitrate", i + 1 < args.count, let val = Int32(args[i+1]) {
                bitrateMbps = val
            } else if args[i] == "--port", i + 1 < args.count, let val = UInt16(args[i+1]) {
                port = val
            }
        }
        
        print("⚙️  Configuration:")
        print("   Resolution: \(width)x\(height) (\(width > height ? "Landscape" : "Portrait"))")
        print("   Frame Rate: \(fps) FPS")
        print("   Bitrate   : \(bitrateMbps) Mbps")
        print("   Port      : \(port)")
        print("")
        
        // 1. Create Virtual Display
        print("🖥️  Creating Virtual Display...")
        let createdID = VDBridgeCreateDisplay("Android Display", width, height, Double(fps), false)
        guard createdID != 0 else {
            print("❌ Failed to create virtual display. Exiting.")
            exit(1)
        }
        self.displayID = createdID
        print("✅ Virtual display created successfully (Display ID: \(displayID))")
        
        // Setup signal handling for clean exit
        setupSignalHandlers()
        
        // Brief pause to allow CoreGraphics and ScreenCaptureKit to register the new display
        try? await Task.sleep(nanoseconds: 800_000_000)
        
        // 2. Setup Touch Injector
        let touch = TouchInjector(displayID: displayID)
        self.touchInjector = touch
        
        // 3. Setup H264 Encoder
        let enc = H264Encoder(
            width: Int32(width),
            height: Int32(height),
            fps: Int32(fps),
            bitrate: bitrateMbps * 1_000_000
        )
        self.encoder = enc
        
        // 4. Setup Network Server
        let netServer = NetworkServer(port: port)
        self.server = netServer
        
        enc.onEncodedFrame = { [weak netServer] frameData in
            netServer?.broadcastFrame(frameData)
        }
        
        netServer.onClientConnected = { [weak enc] in
            print("📲 Client connected! Sending immediate keyframe...")
            enc?.requestKeyframe()
        }
        
        netServer.onTouchEvent = { [weak touch] type, x, y, dy in
            touch?.handleTouchEvent(type: type, normX: x, normY: y, deltaY: dy)
        }
        
        do {
            try netServer.start(width: width, height: height, fps: fps)
        } catch {
            print("❌ Failed to start network server: \(error)")
            cleanup()
            exit(1)
        }
        
        // 5. Start Screen Capturer
        let screenCap = ScreenCapturer(displayID: displayID, width: Int(width), height: Int(height), fps: Int(fps))
        screenCap.delegate = self
        self.capturer = screenCap
        
        do {
            try await screenCap.start()
            print("✅ Screen capture engine running at \(fps) FPS.")
        } catch {
            print("❌ Failed to start screen capturer: \(error)")
            print("💡 Please make sure Screen Recording permission is granted in macOS System Settings.")
            cleanup()
            exit(1)
        }
        
        printConnectionInfo(port: port)
        
        // Keep process running
        while true {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
    
    // MARK: - ScreenCapturerDelegate
    func didCaptureFrame(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        encoder?.encode(pixelBuffer: pixelBuffer, presentationTime: presentationTime)
    }
    
    private func setupSignalHandlers() {
        signal(SIGINT) { _ in
            print("\n🛑 Shutting down server...")
            VDBridgeDestroyDisplay()
            exit(0)
        }
        signal(SIGTERM) { _ in
            print("\n🛑 Terminating server...")
            VDBridgeDestroyDisplay()
            exit(0)
        }
    }
    
    private func cleanup() {
        server?.stop()
        encoder?.invalidate()
        VDBridgeDestroyDisplay()
    }
    
    private func printBanner() {
        print("==================================================")
        print("       🚀 MacScreenServer - Android 2nd Monitor   ")
        print("==================================================")
    }
    
    private func printConnectionInfo(port: UInt16) {
        print("\n✨ Ready for connections!")
        print("--------------------------------------------------")
        print("🔌 USB (Kablolu) Bağlantı:")
        print("   Terminalde şunu çalıştırın:")
        print("   ~/Library/Android/sdk/platform-tools/adb reverse tcp:\(port) tcp:\(port)")
        print("   Telefon uygulamasında 'USB' butonuna basın.")
        print("")
        print("📶 Wi-Fi (Kablosuz) Bağlantı:")
        let ips = getLocalIPAddresses()
        if ips.isEmpty {
            print("   IP bulunamadı (Wi-Fi bağlı olduğundan emin olun).")
        } else {
            for ip in ips {
                print("   IP: \(ip):\(port)")
            }
            print("   Telefon otomatik keşifle (Bonjour) veya yukarıdaki IP ile bağlanabilir.")
        }
        print("--------------------------------------------------\n")
    }
    
    private func getLocalIPAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return [] }
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("en") { // Wi-Fi or Ethernet
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, socklen_t(0), NI_NUMERICHOST)
                    let ip = hostname.withUnsafeBufferPointer { ptr in
                        String(cString: ptr.baseAddress!)
                    }
                    if !ip.isEmpty && ip != "127.0.0.1" {
                        addresses.append(ip)
                    }
                }
            }
        }
        freeifaddrs(ifaddr)
        return addresses
    }
}
