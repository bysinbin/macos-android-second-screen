import SwiftUI
import AppKit
import ScreenCore
import VirtualDisplayBridge

@main
struct MacScreenApp: App {
    @StateObject private var model = AppViewModel()
    
    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(width: 460, height: 520)
                .fixedSize()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var isRunning = false
    @Published var isMirrorMode = false
    @Published var selectedResolution = "1080p"
    @Published var fps: Int = 60
    @Published var bitrateMbps: Int = 10
    @Published var statusText = "Hazır"
    @Published var usbStatus = "Kontrol ediliyor..."
    @Published var isUsbConnected = false
    @Published var localIP = "127.0.0.1"
    
    @Published var isAccessibilityGranted: Bool = true
    @Published var isScreenCaptureGranted: Bool = true
    
    private var usbTimer: Timer?
    
    init() {
        checkAccessibility()
        checkScreenCapture()
        refreshUsbStatus()
        refreshIP()
        usbTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshUsbStatus()
                self?.checkAccessibility()
                self?.checkScreenCapture()
            }
        }
        if isScreenCaptureGranted {
            startServer()
        } else {
            statusText = "⚠️ Ekran kaydı izni bekleniyor..."
        }
    }
    
    func checkAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        isAccessibilityGranted = AXIsProcessTrustedWithOptions(options)
    }
    
    func requestAccessibilityPrompt() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    
    func checkScreenCapture() {
        isScreenCaptureGranted = CGPreflightScreenCaptureAccess()
    }
    
    func requestScreenCapturePrompt() {
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
    
    func toggleServer() {
        if isRunning {
            stopServer()
        } else {
            startServer()
        }
    }
    
    func startServer() {
        checkScreenCapture()
        guard isScreenCaptureGranted else {
            statusText = "❌ Hata: Ekran Kaydı İzni Gerekli"
            requestScreenCapturePrompt()
            return
        }
        
        Task {
            do {
                statusText = "Başlatılıyor..."
                var width: UInt32 = 1920
                var height: UInt32 = 1080
                
                if selectedResolution == "720p" {
                    width = 1640
                    height = 720
                } else if selectedResolution == "1080p" {
                    width = 1920
                    height = 1080
                } else if selectedResolution == "2k" {
                    width = 2160
                    height = 1080
                }
                
                try await ScreenEngine.shared.start(
                    isMirror: isMirrorMode,
                    width: width,
                    height: height,
                    fps: UInt32(fps),
                    bitrateMbps: Int32(bitrateMbps),
                    port: ScreenProtocol.defaultPort
                )
                
                isRunning = true
                statusText = isMirrorMode ? "🪞 Yansıtma Yayında (Port 8888)" : "🖥️ 2. Ekran Yayında (Port 8888)"
                setupUsbReverse()
            } catch {
                statusText = "❌ Hata: \(error.localizedDescription)"
                isRunning = false
            }
        }
    }
    
    func stopServer() {
        Task {
            statusText = "Durduruluyor..."
            await ScreenEngine.shared.stop()
            isRunning = false
            statusText = "Durduruldu"
        }
    }
    
    func setupUsbReverse() {
        let adbPath = "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["reverse", "tcp:8888", "tcp:8888"]
        try? process.run()
    }
    
    func refreshUsbStatus() {
        let adbPath = "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb"
        guard FileManager.default.fileExists(atPath: adbPath) else {
            usbStatus = "ADB bulunamadı"
            isUsbConnected = false
            return
        }
        
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["devices"]
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(decoding: data, as: UTF8.self)
            
            let lines = output.components(separatedBy: "\n").filter { $0.contains("device") && !$0.contains("List") }
            if let first = lines.first {
                let id = first.components(separatedBy: "\t").first ?? "Cihaz"
                usbStatus = "🔌 Cihaz Bağlı: \(id)"
                isUsbConnected = true
            } else {
                usbStatus = "⚪ USB Cihazı Bekleniyor"
                isUsbConnected = false
            }
        } catch {
            usbStatus = "ADB hatası"
            isUsbConnected = false
        }
    }
    
    func refreshIP() {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return }
        
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
        if let first = addresses.first {
            localIP = first
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppViewModel
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                Image(systemName: "display.2")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mac Screen")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.isRunning ? Color.green : Color.gray)
                            .frame(width: 8, height: 8)
                        Text(model.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
            }
            .padding(.top, 10)
            
            Divider()
            
            if !model.isScreenCaptureGranted {
                HStack(spacing: 8) {
                    Image(systemName: "video.slash.fill")
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ekran Kaydı İzni Gerekli")
                            .font(.caption)
                            .fontWeight(.bold)
                        Text("Görüntü aktarımı için Sistem Ayarları'ndan 'Ekran ve Sistem Sesi Kaydı' iznini açın.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("İzni Aç") {
                        model.requestScreenCapturePrompt()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.12)))
            }
            
            if !model.isAccessibilityGranted {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Dokunmatik & Tıklama için izin gerekli.")
                        .font(.caption)
                    Spacer()
                    Button("İzin Ver") {
                        model.requestAccessibilityPrompt()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.small)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }
            
            // Mode Selection
            VStack(alignment: .leading, spacing: 8) {
                Text("Ekran Modu")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                
                Picker("", selection: $model.isMirrorMode) {
                    Text("🖥️ Genişletilmiş 2. Ekran").tag(false)
                    Text("🪞 Ekranı Yansıt (Mirror)").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(model.isRunning)
            }
            
            // Resolution Selection
            VStack(alignment: .leading, spacing: 8) {
                Text("Çözünürlük Kalitesi")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                
                Picker("", selection: $model.selectedResolution) {
                    Text("1080p Full HD (Önerilen)").tag("1080p")
                    Text("720p Hızlı").tag("720p")
                    Text("2K Retina").tag("2k")
                }
                .pickerStyle(.segmented)
                .disabled(model.isRunning)
            }
            
            // USB & Wi-Fi Card
            VStack(spacing: 10) {
                HStack {
                    Image(systemName: model.isUsbConnected ? "cable.connector" : "cable.connector.slash")
                        .foregroundStyle(model.isUsbConnected ? .green : .secondary)
                    Text(model.usbStatus)
                        .font(.subheadline)
                    Spacer()
                    Button("Port Bağla") {
                        model.setupUsbReverse()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                
                HStack {
                    Image(systemName: "wifi")
                        .foregroundStyle(.cyan)
                    Text("Wi-Fi IP: \(model.localIP):8888")
                        .font(.subheadline)
                    Spacer()
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
            
            Spacer()
            
            // Big Action Button
            Button(action: {
                model.toggleServer()
            }) {
                HStack(spacing: 8) {
                    Image(systemName: model.isRunning ? "stop.fill" : "play.fill")
                    Text(model.isRunning ? "YAYINI DURDUR" : "YAYINI BAŞLAT")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 38)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isRunning ? .red : .blue)
            .controlSize(.large)
        }
        .padding(24)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
