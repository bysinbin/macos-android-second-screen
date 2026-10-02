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
                .frame(width: 520, height: 680)
                .fixedSize()
                .task {
                    model.onAppear()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

// MARK: - Screen Item View Model

public struct ScreenItemState: Identifiable {
    public let id: UUID
    public var name: String
    public var port: UInt16
    public var isRunning: Bool
    public var resolution: String // "1080p", "720p", "2k"
    public var isMirror: Bool
    public var statusText: String
}

@MainActor
final class AppViewModel: ObservableObject {
    @Published var screens: [ScreenItemState] = []
    @Published var usbStatus = "Kontrol ediliyor..."
    @Published var isUsbConnected = false
    @Published var localIP = "127.0.0.1"
    
    // Touch Bar Support
    @Published var isTouchBarRunning = false
    @Published var touchBarStatusText = "Hazır"
    @Published var isTouchBarAvailable = true
    
    @Published var isAccessibilityGranted: Bool = false
    @Published var isInputMonitoringGranted: Bool = false
    @Published var isScreenCaptureGranted: Bool = false
    
    private var usbTimer: Timer?
    private var hasAppeared = false
    
    init() {
        checkAccessibility()
        checkInputMonitoring()
        checkScreenCapture()
        
        // Initialize default screen 1
        let def = ScreenServerManager.shared.defaultServer
        screens = [
            ScreenItemState(
                id: def.id,
                name: def.name,
                port: def.port,
                isRunning: def.isRunning,
                resolution: "1080p",
                isMirror: false,
                statusText: "Hazır"
            )
        ]
    }
    
    func onAppear() {
        guard !hasAppeared else { return }
        hasAppeared = true
        
        checkAccessibility()
        checkInputMonitoring()
        checkScreenCapture()
        refreshUsbStatus()
        refreshIP()
        
        usbTimer?.invalidate()
        usbTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshUsbStatus()
                self?.checkAccessibility()
                self?.checkInputMonitoring()
                self?.checkScreenCapture()
            }
        }
        
        if !isAccessibilityGranted {
            requestAccessibilityPrompt()
        }
        
        if !isScreenCaptureGranted {
            requestScreenCapturePrompt()
        } else {
            // Auto start first screen
            if let first = screens.first, !first.isRunning {
                startScreen(id: first.id)
            }
        }
        
        if isTouchBarAvailable && !isTouchBarRunning {
            startTouchBar()
        }
    }
    
    func checkAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        isAccessibilityGranted = AXIsProcessTrustedWithOptions(options)
    }
    
    func requestAccessibilityPrompt() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        isAccessibilityGranted = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    
    func checkInputMonitoring() {
        isInputMonitoringGranted = CGPreflightListenEventAccess()
    }
    
    func requestInputMonitoringPrompt() {
        _ = CGRequestListenEventAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
    
    func checkScreenCapture() {
        isScreenCaptureGranted = CGPreflightScreenCaptureAccess()
    }
    
    func requestScreenCapturePrompt() {
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
    
    // MARK: - Multi-Display Management
    
    func addNewScreen() {
        let instance = ScreenServerManager.shared.addServer()
        let state = ScreenItemState(
            id: instance.id,
            name: instance.name,
            port: instance.port,
            isRunning: false,
            resolution: "1080p",
            isMirror: false,
            statusText: "Hazır"
        )
        screens.append(state)
        setupUsbReverse()
    }
    
    func removeScreen(id: UUID) {
        guard screens.count > 1 else { return }
        Task {
            await ScreenServerManager.shared.removeServer(id: id)
            if let idx = screens.firstIndex(where: { $0.id == id }) {
                screens.remove(at: idx)
            }
            setupUsbReverse()
        }
    }
    
    func toggleScreen(id: UUID) {
        guard let item = screens.first(where: { $0.id == id }) else { return }
        if item.isRunning {
            stopScreen(id: id)
        } else {
            startScreen(id: id)
        }
    }
    
    func startScreen(id: UUID) {
        checkScreenCapture()
        guard isScreenCaptureGranted else {
            requestScreenCapturePrompt()
            return
        }
        
        guard let idx = screens.firstIndex(where: { $0.id == id }) else { return }
        let item = screens[idx]
        
        guard let instance = ScreenServerManager.shared.servers.first(where: { $0.id == id }) else { return }
        
        screens[idx].statusText = "Başlatılıyor..."
        
        var width: UInt32 = 1920
        var height: UInt32 = 1080
        if item.resolution == "720p" {
            width = 1640
            height = 720
        } else if item.resolution == "1080p" {
            width = 1920
            height = 1080
        } else if item.resolution == "2k" {
            width = 2160
            height = 1080
        }
        
        Task {
            do {
                try await instance.start(
                    isMirror: item.isMirror,
                    width: width,
                    height: height,
                    fps: 60,
                    bitrateMbps: 10
                )
                screens[idx].isRunning = true
                screens[idx].statusText = item.isMirror ? "🪞 Yansıtma (Port \(instance.port))" : "🖥️ Aktif (Port \(instance.port))"
                setupUsbReverse()
            } catch {
                screens[idx].statusText = "❌ \(error.localizedDescription)"
                screens[idx].isRunning = false
            }
        }
    }
    
    func stopScreen(id: UUID) {
        guard let idx = screens.firstIndex(where: { $0.id == id }) else { return }
        guard let instance = ScreenServerManager.shared.servers.first(where: { $0.id == id }) else { return }
        
        screens[idx].statusText = "Durduruluyor..."
        Task {
            await instance.stop()
            screens[idx].isRunning = false
            screens[idx].statusText = "Durduruldu"
        }
    }
    
    // MARK: - Touch Bar
    
    func toggleTouchBar() {
        if isTouchBarRunning {
            stopTouchBar()
        } else {
            startTouchBar()
        }
    }
    
    func startTouchBar() {
        do {
            try TouchBarEngine.shared.start(port: ScreenProtocol.touchBarPort)
            isTouchBarRunning = true
            touchBarStatusText = "🪄 Touch Bar Yayında (Port 8889)"
            setupUsbReverse()
        } catch {
            touchBarStatusText = "❌ \(error.localizedDescription)"
            isTouchBarRunning = false
        }
    }
    
    func stopTouchBar() {
        TouchBarEngine.shared.stop()
        isTouchBarRunning = false
        touchBarStatusText = "Durduruldu"
    }
    
    // MARK: - Port Forwarding & Networking
    
    func setupUsbReverse() {
        let adbPath = "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb"
        guard FileManager.default.fileExists(atPath: adbPath) else { return }
        
        // Reverse Touch Bar port
        let ptb = Process()
        ptb.executableURL = URL(fileURLWithPath: adbPath)
        ptb.arguments = ["reverse", "tcp:8889", "tcp:8889"]
        try? ptb.run()
        
        // Reverse all active screen ports
        for s in ScreenServerManager.shared.servers {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: adbPath)
            p.arguments = ["reverse", "tcp:\(s.port)", "tcp:\(s.port)"]
            try? p.run()
        }
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
                setupUsbReverse()
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

// MARK: - Main Content View

struct ContentView: View {
    @ObservedObject var model: AppViewModel
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "display.2")
                    .font(.system(size: 26))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mac Screen Studio")
                        .font(.headline)
                        .fontWeight(.bold)
                    Text("Çoklu Sanal Ekran & Touch Bar Dağıtıcısı")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                
                Button(action: {
                    model.addNewScreen()
                }) {
                    Label("Ekran Ekle", systemImage: "plus.circle.fill")
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.top, 4)
            
            Divider()
            
            // Permissions Alerts
            VStack(spacing: 8) {
                if !model.isAccessibilityGranted {
                    HStack(spacing: 8) {
                        Image(systemName: "hand.point.up.left.and.text")
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Erişilebilirlik İzni Gerekli")
                                .font(.caption)
                                .fontWeight(.bold)
                            Text("Fare tıklamaları ve dokunmatik kontrol için 'Erişilebilirlik' iznini açın.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("İzni Aç") {
                            model.requestAccessibilityPrompt()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.small)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.12)))
                }
                
                if !model.isInputMonitoringGranted {
                    HStack(spacing: 8) {
                        Image(systemName: "keyboard.badge.waveform")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Giriş İzleme (Input Monitoring) Gerekli")
                                .font(.caption)
                                .fontWeight(.bold)
                            Text("3 parmak jestleri ve klavye kısayolları için 'Giriş İzleme' iznini açın.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("İzni Aç") {
                            model.requestInputMonitoringPrompt()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.small)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                }

                if !model.isScreenCaptureGranted {
                    HStack(spacing: 8) {
                        Image(systemName: "video.slash.fill")
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ekran Kaydı İzni Gerekli")
                                .font(.caption)
                                .fontWeight(.bold)
                            Text("Yayın için 'Ekran ve Sistem Sesi Kaydı' iznini açın.")
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
                
                if model.isAccessibilityGranted && model.isInputMonitoringGranted && model.isScreenCaptureGranted {
                    HStack {
                        Image(systemName: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 12))
                        Text("Tüm Sistem Yetkileri Aktif")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.green)
                        Spacer()
                        Menu("Yetkileri Yönet") {
                            Button("Erişilebilirlik (Accessibility)") { model.requestAccessibilityPrompt() }
                            Button("Giriş İzleme (Input Monitoring)") { model.requestInputMonitoringPrompt() }
                            Button("Ekran Kaydı (Screen Recording)") { model.requestScreenCapturePrompt() }
                        }
                        .font(.caption2)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.green.opacity(0.08)))
                }
            }
            
            // Scrollable Content
            ScrollView {
                VStack(spacing: 14) {
                    // Touch Bar Standalone Card
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "hand.tap.fill")
                                .foregroundStyle(.purple)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Apple Touch Bar Yayını")
                                    .font(.subheadline)
                                    .fontWeight(.bold)
                                Text("Port: 8889  ·  \(model.touchBarStatusText)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                            
                            Circle()
                                .fill(model.isTouchBarRunning ? Color.green : Color.gray)
                                .frame(width: 8, height: 8)
                            
                            Button(model.isTouchBarRunning ? "Durdur" : "Başlat") {
                                model.toggleTouchBar()
                            }
                            .buttonStyle(.bordered)
                            .tint(model.isTouchBarRunning ? .red : .purple)
                            .controlSize(.small)
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.purple.opacity(0.2), lineWidth: 1))
                    
                    // Displays List
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Sanal Ekranlar (\(model.screens.count))")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        
                        ForEach($model.screens) { $item in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: item.isRunning ? "tv.fill" : "tv")
                                        .foregroundStyle(item.isRunning ? .blue : .secondary)
                                    Text(item.name)
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                    
                                    Text("(Port \(item.port))")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    
                                    Spacer()
                                    
                                    Circle()
                                        .fill(item.isRunning ? Color.green : Color.gray)
                                        .frame(width: 8, height: 8)
                                    
                                    Button(item.isRunning ? "Durdur" : "Başlat") {
                                        model.toggleScreen(id: item.id)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(item.isRunning ? .red : .blue)
                                    .controlSize(.small)
                                    
                                    if model.screens.count > 1 {
                                        Button(action: {
                                            model.removeScreen(id: item.id)
                                        }) {
                                            Image(systemName: "trash")
                                                .foregroundStyle(.red)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(item.isRunning)
                                    }
                                }
                                
                                HStack(spacing: 8) {
                                    Picker("", selection: $item.resolution) {
                                        Text("1080p").tag("1080p")
                                        Text("720p").tag("720p")
                                        Text("2K").tag("2k")
                                    }
                                    .pickerStyle(.segmented)
                                    .controlSize(.small)
                                    .disabled(item.isRunning)
                                    
                                    Picker("", selection: $item.isMirror) {
                                        Text("Genişlet").tag(false)
                                        Text("Yansıt").tag(true)
                                    }
                                    .pickerStyle(.segmented)
                                    .controlSize(.small)
                                    .disabled(item.isRunning)
                                }
                                
                                Text(item.statusText)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.08), lineWidth: 1))
                        }
                    }
                    
                    // Network & USB Card
                    VStack(spacing: 8) {
                        HStack {
                            Image(systemName: model.isUsbConnected ? "cable.connector" : "cable.connector.slash")
                                .foregroundStyle(model.isUsbConnected ? .green : .secondary)
                            Text(model.usbStatus)
                                .font(.caption)
                            Spacer()
                            Button("Portları Bağla") {
                                model.setupUsbReverse()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                        
                        HStack {
                            Image(systemName: "wifi")
                                .foregroundStyle(.cyan)
                            Text("Wi-Fi IP: \(model.localIP)")
                                .font(.caption)
                            Spacer()
                            Text("Touch Bar: 8889  ·  Ekranlar: \(model.screens.map { String($0.port) }.joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
                }
            }
        }
        .padding(20)
        .background(Color(NSColor.windowBackgroundColor))
    }
}
