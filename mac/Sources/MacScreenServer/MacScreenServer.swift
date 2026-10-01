import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import VirtualDisplayBridge
import ScreenCore

@main
final class MacScreenServerApp: @unchecked Sendable, ScreenCapturerDelegate {
    private var displayID: CGDirectDisplayID = 0
    private var isMirrorMode: Bool = false
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
        
        var isMirror = false
        var width: UInt32 = 1920
        var height: UInt32 = 1080
        var fps: UInt32 = 60
        var bitrateMbps: Int32 = 10 // High bitrate (10 Mbps) for razor-sharp text
        var port: UInt16 = ScreenProtocol.defaultPort
        
        let args = CommandLine.arguments
        for i in 1..<args.count {
            if args[i] == "--mirror" {
                isMirror = true
            } else if args[i] == "--extend" {
                isMirror = false
            } else if args[i] == "--portrait" {
                width = 720
                height = 1640
            } else if args[i] == "--landscape" {
                width = 1640
                height = 720
            } else if args[i] == "--res", i + 1 < args.count {
                let resChoice = args[i+1].lowercased()
                if resChoice == "720p" {
                    width = 1640
                    height = 720
                } else if resChoice == "1080p" {
                    width = 1920
                    height = 1080
                } else if resChoice == "2k" {
                    width = 2160
                    height = 1080
                }
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
        
        self.isMirrorMode = isMirror
        
        if isMirror {
            print("🪞  Mod: YANSITMA (Mac Ekranı Doğrudan Aynalanıyor - Mac Çözünürlüğü Korunur)")
            let mainID = CGMainDisplayID()
            let mainBounds = CGDisplayBounds(mainID)
            let aspect = mainBounds.width / mainBounds.height
            // High resolution capture matching Mac aspect ratio (e.g. 1920x1200 on 16:10 MacBook)
            width = 1920
            var calcH = UInt32(round(1920.0 / aspect))
            if calcH % 2 != 0 { calcH += 1 } // Even height for H.264
            height = calcH
            self.displayID = mainID
            print("   Mac Çözünürlüğü : \(Int(mainBounds.width))x\(Int(mainBounds.height)) (Değişmedi)")
            print("   Yayın Çözünürlüğü: \(width)x\(height) (Yüksek Çözünürlüklü GPU Ölçekleme)")
        } else {
            print("🖥️  Mod: GENİŞLETİLMİŞ MASAÜSTÜ (Bağımsız 2. Ekran)")
            print("🖥️  Sanal Monitör Oluşturuluyor...")
            let createdID = VDBridgeCreateDisplay("Android Display", width, height, Double(fps), false)
            guard createdID != 0 else {
                print("❌ Sanal ekran oluşturulamadı. Çıkılıyor.")
                exit(1)
            }
            self.displayID = createdID
            print("✅ Sanal ekran oluşturuldu (Display ID: \(displayID), \(width)x\(height))")
        }
        
        print("⚙️  Ayrıntılar:")
        print("   Kare Hızı: \(fps) FPS")
        print("   Bit Hızı : \(bitrateMbps) Mbps (Yüksek Kalite)")
        print("   Port     : \(port)")
        print("")
        
        setupSignalHandlers()
        
        // Brief pause to allow CoreGraphics and ScreenCaptureKit to register
        try? await Task.sleep(nanoseconds: 600_000_000)
        
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
        
        let screenCap = ScreenCapturer(displayID: displayID, width: Int(width), height: Int(height), fps: Int(fps))
        screenCap.delegate = self
        self.capturer = screenCap
        
        enc.onEncodedFrame = { [weak netServer] frameData in
            netServer?.broadcastFrame(frameData)
        }
        
        netServer.onClientConnected = { [weak enc, weak screenCap, weak netServer] in
            print("📲 İstemci bağlandı! Ana kare (Keyframe) gönderiliyor...")
            if let cached = enc?.lastKeyframe {
                netServer?.broadcastFrame(cached)
            }
            enc?.requestKeyframe()
            screenCap?.kickstart()
        }
        
        netServer.onTouchEvent = { [weak touch] type, x, y, dy in
            touch?.handleTouchEvent(type: type, normX: x, normY: y, deltaY: dy)
        }
        
        do {
            try netServer.start(width: width, height: height, fps: fps)
        } catch {
            print("❌ Ağ sunucusu başlatılamadı: \(error)")
            cleanup()
            exit(1)
        }
        
        do {
            try await screenCap.start()
            print("✅ Ekran yakalama motoru \(fps) FPS hızında çalışıyor.")
        } catch {
            print("❌ Ekran yakalanamadı: \(error)")
            cleanup()
            exit(1)
        }
        
        printConnectionInfo(port: port)
        
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
            print("\n🛑 Sunucu durduruluyor...")
            VDBridgeDestroyDisplay()
            exit(0)
        }
        signal(SIGTERM) { _ in
            print("\n🛑 Sunucu sonlandırılıyor...")
            VDBridgeDestroyDisplay()
            exit(0)
        }
    }
    
    private func cleanup() {
        server?.stop()
        encoder?.invalidate()
        if !isMirrorMode {
            VDBridgeDestroyDisplay()
        }
    }
    
    private func printBanner() {
        print("==================================================")
        print("       🚀 MacScreenServer - Android 2nd Monitor   ")
        print("==================================================")
    }
    
    private func printConnectionInfo(port: UInt16) {
        print("\n✨ Bağlantıya hazır!")
        print("--------------------------------------------------")
        print("🔌 USB (Kablolu) Bağlantı:")
        print("   adb reverse tcp:\(port) tcp:\(port)")
        print("   Telefon uygulamasında 'USB' butonuna basın.")
        print("")
        print("📶 Wi-Fi (Kablosuz) Bağlantı:")
        let ips = getLocalIPAddresses()
        if ips.isEmpty {
            print("   IP bulunamadı.")
        } else {
            for ip in ips {
                print("   IP: \(ip):\(port)")
            }
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
                if name.hasPrefix("en") {
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
