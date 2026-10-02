import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Cocoa
import CoreAudio
import AudioToolbox
import VirtualDisplayBridge

// MARK: - Touch Bar Configuration (JSON)

struct TouchBarButtonConfig: Codable {
    let title: String?
    let icon: String?      // SF Symbol name
    let shortcut: String   // e.g. "cmd+/", "shift+up", "cmd+shift+k"
}

struct TouchBarAppEntry: Codable {
    let buttons: [TouchBarButtonConfig]
}

struct TouchBarConfigFile: Codable {
    let apps: [String: TouchBarAppEntry]
}

// MARK: - Key Code Mapping

private let keyCodeMap: [String: UInt16] = [
    "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
    "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
    "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11,
    "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17, "6": 0x16,
    "7": 0x1A, "8": 0x1C, "9": 0x19, "0": 0x1D,
    "=": 0x18, "-": 0x1B, "]": 0x1E, "[": 0x21, "'": 0x27, ";": 0x29,
    "\\": 0x2A, ",": 0x2B, "/": 0x2C, ".": 0x2F, "`": 0x32,
    "o": 0x1F, "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26,
    "k": 0x28, "n": 0x2D, "m": 0x2E,
    "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31,
    "delete": 0x33, "backspace": 0x33, "escape": 0x35, "esc": 0x35,
    "up": 0x7E, "down": 0x7D, "left": 0x7B, "right": 0x7C,
    "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
    "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76,
    "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
    "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
]

private func parseShortcut(_ shortcut: String) -> (keyCode: UInt16, flags: CGEventFlags)? {
    let parts = shortcut.lowercased().split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
    guard !parts.isEmpty else { return nil }
    
    var flags: CGEventFlags = []
    var keyPart: String? = nil
    
    for part in parts {
        switch part {
        case "cmd", "command": flags.insert(.maskCommand)
        case "shift": flags.insert(.maskShift)
        case "alt", "opt", "option": flags.insert(.maskAlternate)
        case "ctrl", "control": flags.insert(.maskControl)
        default: keyPart = part
        }
    }
    
    guard let key = keyPart, let code = keyCodeMap[key] else { return nil }
    return (code, flags)
}

// MARK: - TouchBarEngine

public final class TouchBarEngine: @unchecked Sendable {
    public static let shared = TouchBarEngine()
    
    public private(set) var isRunning: Bool = false
    public var onStatusChanged: (@Sendable (String) -> Void)?
    public var onClientConnected: (@Sendable () -> Void)?
    
    private var encoder: H264Encoder?
    private var server: NetworkServer?
    private let touchInjector = TouchInjector(displayID: CGMainDisplayID())
    
    private var canvasBuffer: CVPixelBuffer?
    private var keepaliveTimer: DispatchSourceTimer?
    private var autoCollapseTimer: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.antigravity.touchbarengine", qos: .userInteractive)
    
    private var frameIndex: Int64 = 0
    private var lastDeliveredTime = Date()
    private let lock = NSLock()
    
    // Canvas dimensions (Proportional to Touch Bar aspect ratio, multiples of 16 for H.264)
    public let canvasWidth: Int = 1600
    public let canvasHeight: Int = 224
    
    // UI Modes
    public enum ActiveMode {
        case normal
        case fn
        case brightnessSwipe
        case volumeSwipe
    }
    private var currentMode: ActiveMode = .normal
    
    private var pressedButtonId: String? = nil
    private var activeAppName: String = "Mac"
    private var activeAppBundleId: String = ""
    private var lastAppUpdateTime = Date.distantPast
    
    // Slider state
    private var activeSlider: String? = nil
    private var brightnessLevel: CGFloat = 0.65
    private var volumeLevel: CGFloat = 0.50
    private var currentVolumeStep: Int = 8
    
    // App config
    private var appConfig: TouchBarConfigFile?
    private var configFileURL: URL {
        let supportDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacScreen")
        return supportDir.appendingPathComponent("touchbar.json")
    }
    
    // Geometry Constants
    private let barH: CGFloat = 200
    private var barY: CGFloat { CGFloat(canvasHeight - Int(barH)) / 2.0 } // 12
    private let btnH: CGFloat = 160
    private var btnY: CGFloat { barY + (barH - btnH) / 2.0 }             // 32
    private let cornerR: CGFloat = 24
    
    private struct TouchBarButton {
        let id: String
        let rect: NSRect
        let title: String
        let sfSymbol: String?
        let action: @Sendable () -> Void
    }
    
    public init() {
        loadConfig()
        let b = VDBridgeGetBrightness()
        brightnessLevel = CGFloat(b)
    }
    
    // MARK: - Config Loading
    
    private func loadConfig() {
        let fm = FileManager.default
        let dir = configFileURL.deletingLastPathComponent()
        
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        
        if !fm.fileExists(atPath: configFileURL.path) {
            createDefaultConfig()
        }
        
        do {
            let data = try Data(contentsOf: configFileURL)
            appConfig = try JSONDecoder().decode(TouchBarConfigFile.self, from: data)
        } catch {
            NSLog("[TouchBar] Config yüklenemedi: \(error.localizedDescription)")
        }
    }
    
    public func reloadConfig() {
        loadConfig()
        renderAndEncode()
    }
    
    private func createDefaultConfig() {
        let defaultConfig: [String: Any] = [
            "apps": [
                "com.microsoft.VSCode": [
                    "buttons": [
                        ["title": "//", "shortcut": "cmd+/"],
                        ["icon": "chevron.up", "shortcut": "alt+up"],
                        ["icon": "chevron.down", "shortcut": "alt+down"],
                        ["icon": "arrow.right.to.line", "shortcut": "cmd+]"],
                        ["icon": "arrow.left.to.line", "shortcut": "cmd+["],
                        ["icon": "terminal", "shortcut": "ctrl+`"],
                        ["title": "⌘P", "shortcut": "cmd+p"],
                        ["icon": "sidebar.left", "shortcut": "cmd+b"]
                    ]
                ],
                "com.google.Chrome": [
                    "buttons": [
                        ["icon": "chevron.left", "shortcut": "cmd+["],
                        ["icon": "chevron.right", "shortcut": "cmd+]"],
                        ["icon": "arrow.clockwise", "shortcut": "cmd+r"],
                        ["icon": "plus", "shortcut": "cmd+t"],
                        ["icon": "xmark", "shortcut": "cmd+w"],
                        ["title": "DevTools", "shortcut": "cmd+alt+i"]
                    ]
                ],
                "com.apple.finder": [
                    "buttons": [
                        ["icon": "eye", "shortcut": "space"],
                        ["icon": "info.circle", "shortcut": "cmd+i"],
                        ["icon": "doc.on.doc", "shortcut": "cmd+d"],
                        ["icon": "trash", "shortcut": "cmd+delete"],
                        ["icon": "folder.badge.plus", "shortcut": "cmd+shift+n"],
                        ["icon": "arrow.up", "shortcut": "cmd+up"]
                    ]
                ],
                "com.apple.Terminal": [
                    "buttons": [
                        ["icon": "plus", "shortcut": "cmd+t"],
                        ["title": "Clear", "shortcut": "cmd+k"],
                        ["icon": "doc.on.clipboard", "shortcut": "cmd+v"],
                        ["title": "^C", "shortcut": "ctrl+c"]
                    ]
                ],
                "com.apple.dt.Xcode": [
                    "buttons": [
                        ["icon": "play.fill", "shortcut": "cmd+r"],
                        ["icon": "stop.fill", "shortcut": "cmd+."],
                        ["title": "Build", "shortcut": "cmd+b"],
                        ["title": "Clean", "shortcut": "cmd+shift+k"],
                        ["icon": "magnifyingglass", "shortcut": "cmd+shift+o"]
                    ]
                ]
            ]
        ]
        
        do {
            let data = try JSONSerialization.data(withJSONObject: defaultConfig, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: configFileURL)
            NSLog("[TouchBar] Varsayılan config oluşturuldu: \(configFileURL.path)")
        } catch {
            NSLog("[TouchBar] Config oluşturulamadı: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Lifecycle
    
    public func start(port: UInt16 = ScreenProtocol.touchBarPort) throws {
        guard !isRunning else { return }
        
        loadConfig()
        setupCanvasBuffer()
        
        let enc = H264Encoder(width: Int32(canvasWidth), height: Int32(canvasHeight), fps: 60, bitrate: 3_000_000)
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
            self?.renderAndEncode()
            self?.onClientConnected?()
        }
        
        netServer.onTouchEvent = { [weak self] type, normX, normY, deltaY in
            if type >= 0x05 && type <= 0x0D {
                self?.touchInjector.handleTouchEvent(type: type, normX: normX, normY: normY, deltaY: deltaY)
            } else {
                self?.handleTouch(type: type, normX: normX, normY: normY)
            }
        }
        
        try netServer.start(width: UInt32(canvasWidth), height: UInt32(canvasHeight), fps: 60)
        
        renderAndEncode()
        startKeepalive()
        
        self.isRunning = true
        onStatusChanged?("🪄 Touch Bar Yayında (Port \(port))")
    }
    
    public func stop() {
        guard isRunning else { return }
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
        autoCollapseTimer?.cancel()
        autoCollapseTimer = nil
        server?.stop()
        server = nil
        encoder = nil
        canvasBuffer = nil
        isRunning = false
        onStatusChanged?("Durduruldu")
    }
    
    private func setupCanvasBuffer() {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: canvasWidth,
            kCVPixelBufferHeightKey: canvasHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, canvasWidth, canvasHeight, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &canvasBuffer)
    }
    
    // MARK: - Auto Collapse for Sliders
    
    private func resetAutoCollapseTimer(delay: TimeInterval = 4.0) {
        autoCollapseTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            if self.currentMode == .brightnessSwipe || self.currentMode == .volumeSwipe {
                self.currentMode = .normal
                self.activeSlider = nil
                self.lock.unlock()
                self.renderAndEncode()
            } else {
                self.lock.unlock()
            }
        }
        autoCollapseTimer = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }
    
    // MARK: - Button Layouts
    
    private func getAppButtons() -> [TouchBarButton] {
        guard let config = appConfig,
              let appEntry = config.apps[activeAppBundleId],
              !appEntry.buttons.isEmpty else {
            return []
        }
        
        var buttons = [TouchBarButton]()
        let y = btnY
        let h = btnH
        let startX: CGFloat = 630
        let availableW: CGFloat = 630 // x: 630 to 1260
        let maxBtns = min(appEntry.buttons.count, 6)
        let spacing: CGFloat = 10
        let btnW = (availableW - CGFloat(maxBtns - 1) * spacing) / CGFloat(maxBtns)
        
        for idx in 0..<maxBtns {
            let cfg = appEntry.buttons[idx]
            let x = startX + CGFloat(idx) * (btnW + spacing)
            let title = cfg.title ?? ""
            let icon = cfg.icon
            let shortcutStr = cfg.shortcut
            
            buttons.append(TouchBarButton(
                id: "app_\(idx)",
                rect: NSRect(x: x, y: y, width: btnW, height: h),
                title: title,
                sfSymbol: icon
            ) {
                guard let parsed = parseShortcut(shortcutStr) else { return }
                let src = CGEventSource(stateID: .hidSystemState)
                let down = CGEvent(keyboardEventSource: src, virtualKey: parsed.keyCode, keyDown: true)
                down?.flags = parsed.flags
                let up = CGEvent(keyboardEventSource: src, virtualKey: parsed.keyCode, keyDown: false)
                up?.flags = parsed.flags
                down?.post(tap: .cghidEventTap)
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) {
                    up?.post(tap: .cghidEventTap)
                }
            })
        }
        
        return buttons
    }
    
    private func getButtons() -> [TouchBarButton] {
        var buttons = [TouchBarButton]()
        let y = btnY
        let h = btnH
        
        switch currentMode {
        case .fn:
            // ESC
            buttons.append(TouchBarButton(id: "esc", rect: NSRect(x: 24, y: y, width: 104, height: h), title: "esc", sfSymbol: nil) {
                VDBridgePostVirtualKey(0x35, true)
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                    VDBridgePostVirtualKey(0x35, false)
                }
            })
            // fn toggle (active)
            buttons.append(TouchBarButton(id: "fn", rect: NSRect(x: 136, y: y, width: 84, height: h), title: "fn", sfSymbol: nil) { [weak self] in
                guard let self = self else { return }
                self.lock.lock()
                self.currentMode = .normal
                self.lock.unlock()
            })
            
            let fKeys: [(String, UInt16)] = [
                ("F1", 0x7A), ("F2", 0x78), ("F3", 0x63), ("F4", 0x76),
                ("F5", 0x60), ("F6", 0x61), ("F7", 0x62), ("F8", 0x64),
                ("F9", 0x65), ("F10", 0x6D), ("F11", 0x67), ("F12", 0x6F)
            ]
            let startX: CGFloat = 228
            let spacing: CGFloat = 8
            let btnW: CGFloat = (1576 - startX - CGFloat(11) * spacing) / 12.0 // ~104
            
            for (idx, (name, keyCode)) in fKeys.enumerated() {
                let x = startX + CGFloat(idx) * (btnW + spacing)
                buttons.append(TouchBarButton(id: name.lowercased(), rect: NSRect(x: x, y: y, width: btnW, height: h), title: name, sfSymbol: nil) {
                    VDBridgePostVirtualKey(keyCode, true)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                        VDBridgePostVirtualKey(keyCode, false)
                    }
                })
            }
            
        case .brightnessSwipe:
            // Close / Done button on left
            buttons.append(TouchBarButton(id: "close_swipe", rect: NSRect(x: 24, y: y, width: 124, height: h), title: "Bitti", sfSymbol: "xmark") { [weak self] in
                guard let self = self else { return }
                self.lock.lock()
                self.currentMode = .normal
                self.activeSlider = nil
                self.lock.unlock()
            })
            
        case .volumeSwipe:
            // Close / Done button on left
            buttons.append(TouchBarButton(id: "close_swipe", rect: NSRect(x: 24, y: y, width: 124, height: h), title: "Bitti", sfSymbol: "xmark") { [weak self] in
                guard let self = self else { return }
                self.lock.lock()
                self.currentMode = .normal
                self.activeSlider = nil
                self.lock.unlock()
            })
            // Mute toggle on right
            buttons.append(TouchBarButton(id: "mute", rect: NSRect(x: 1466, y: y, width: 110, height: h), title: "Sessiz", sfSymbol: "speaker.slash.fill") {
                toggleSystemMute()
            })
            
        case .normal:
            // ESC
            buttons.append(TouchBarButton(id: "esc", rect: NSRect(x: 24, y: y, width: 104, height: h), title: "esc", sfSymbol: nil) {
                if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x35, keyDown: true) {
                    down.post(tap: .cghidEventTap)
                }
                usleep(25000)
                if let up = CGEvent(keyboardEventSource: nil, virtualKey: 0x35, keyDown: false) {
                    up.post(tap: .cghidEventTap)
                }
            })
            
            // fn toggle
            buttons.append(TouchBarButton(id: "fn", rect: NSRect(x: 136, y: y, width: 84, height: h), title: "fn", sfSymbol: nil) { [weak self] in
                guard let self = self else { return }
                self.lock.lock()
                self.currentMode = .fn
                self.lock.unlock()
            })
            
            // Media keys
            buttons.append(TouchBarButton(id: "prev", rect: NSRect(x: 228, y: y, width: 72, height: h), title: "", sfSymbol: "backward.fill") {
                VDBridgePostSystemMediaKey(18)
            })
            buttons.append(TouchBarButton(id: "play", rect: NSRect(x: 308, y: y, width: 72, height: h), title: "", sfSymbol: "playpause.fill") {
                VDBridgePostSystemMediaKey(16)
            })
            buttons.append(TouchBarButton(id: "next", rect: NSRect(x: 388, y: y, width: 72, height: h), title: "", sfSymbol: "forward.fill") {
                VDBridgePostSystemMediaKey(17)
            })
            
            // Quick tools
            buttons.append(TouchBarButton(id: "search", rect: NSRect(x: 468, y: y, width: 72, height: h), title: "", sfSymbol: "magnifyingglass") {
                if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x31, keyDown: true) {
                    down.flags = .maskCommand
                    down.post(tap: .cghidEventTap)
                }
                usleep(25000)
                if let up = CGEvent(keyboardEventSource: nil, virtualKey: 0x31, keyDown: false) {
                    up.flags = .maskCommand
                    up.post(tap: .cghidEventTap)
                }
            })
            buttons.append(TouchBarButton(id: "screenshot", rect: NSRect(x: 548, y: y, width: 72, height: h), title: "", sfSymbol: "camera.fill") {
                if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x15, keyDown: true) {
                    down.flags = [.maskCommand, .maskShift]
                    down.post(tap: .cghidEventTap)
                }
                usleep(25000)
                if let up = CGEvent(keyboardEventSource: nil, virtualKey: 0x15, keyDown: false) {
                    up.flags = [.maskCommand, .maskShift]
                    up.post(tap: .cghidEventTap)
                }
            })
            
            // Middle App Buttons
            buttons.append(contentsOf: getAppButtons())
            
            // Right section: Brightness (ICON), Volume (ICON), Mute (ICON)
            // Brightness Icon -> Tapping expands/collapses Brightness Swipe Slider!
            buttons.append(TouchBarButton(id: "brightness_icon", rect: NSRect(x: 1276, y: y, width: 96, height: h), title: "", sfSymbol: "sun.max.fill") { [weak self] in
                guard let self = self else { return }
                self.lock.lock()
                if self.currentMode == .brightnessSwipe {
                    self.currentMode = .normal
                    self.activeSlider = nil
                } else {
                    self.currentMode = .brightnessSwipe
                    self.activeSlider = nil
                    let currentB = VDBridgeGetBrightness()
                    self.brightnessLevel = CGFloat(currentB)
                    self.resetAutoCollapseTimer(delay: 5.0)
                }
                self.lock.unlock()
            })
            
            // Volume Icon -> Tapping expands/collapses Volume Swipe Slider!
            buttons.append(TouchBarButton(id: "volume_icon", rect: NSRect(x: 1380, y: y, width: 96, height: h), title: "", sfSymbol: "speaker.wave.2.fill") { [weak self] in
                guard let self = self else { return }
                self.lock.lock()
                if self.currentMode == .volumeSwipe {
                    self.currentMode = .normal
                    self.activeSlider = nil
                } else {
                    self.currentMode = .volumeSwipe
                    self.activeSlider = nil
                    let vol = getSystemVolume()
                    self.volumeLevel = CGFloat(vol)
                    self.resetAutoCollapseTimer(delay: 5.0)
                }
                self.lock.unlock()
            })
            
            // Mute Icon
            buttons.append(TouchBarButton(id: "mute", rect: NSRect(x: 1484, y: y, width: 92, height: h), title: "", sfSymbol: "speaker.slash.fill") {
                toggleSystemMute()
            })
        }
        
        return buttons
    }
    
    // MARK: - Swipe Slider Geometry
    
    private var brightnessSwipeTrackRect: NSRect {
        NSRect(x: 230, y: btnY, width: 1330, height: btnH)
    }
    
    private var volumeSwipeTrackRect: NSRect {
        NSRect(x: 230, y: btnY, width: 1210, height: btnH)
    }
    
    // MARK: - Rendering
    
    private func renderAndEncode() {
        queue.async { [weak self] in
            guard let self = self, let canvas = self.canvasBuffer else { return }
            
            // Update frontmost app info periodically
            if Date().timeIntervalSince(self.lastAppUpdateTime) > 0.5 {
                self.lastAppUpdateTime = Date()
                if let app = NSWorkspace.shared.frontmostApplication {
                    let newBundleId = app.bundleIdentifier ?? ""
                    if newBundleId != self.activeAppBundleId {
                        self.activeAppBundleId = newBundleId
                        self.activeAppName = app.localizedName ?? "Mac"
                    }
                }
            }
            
            CVPixelBufferLockBaseAddress(canvas, [])
            defer { CVPixelBufferUnlockBaseAddress(canvas, []) }
            
            guard let baseAddress = CVPixelBufferGetBaseAddress(canvas) else { return }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(canvas)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            
            guard let ctx = CGContext(
                data: baseAddress,
                width: self.canvasWidth,
                height: self.canvasHeight,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return }
            
            let graphicsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
            let prevGC = NSGraphicsContext.current
            NSGraphicsContext.current = graphicsContext
            defer { NSGraphicsContext.current = prevGC }
            
            // 1. Overall Background (Clean deep dark OLED)
            ctx.setFillColor(CGColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1.0))
            ctx.fill(CGRect(x: 0, y: 0, width: self.canvasWidth, height: self.canvasHeight))
            
            // 2. Touch Bar Outer Container Pill / Deck
            let barContainerRect = NSRect(x: 12, y: self.barY, width: CGFloat(self.canvasWidth) - 24, height: self.barH)
            let barPath = NSBezierPath(roundedRect: barContainerRect, xRadius: self.cornerR + 8, yRadius: self.cornerR + 8)
            NSColor(red: 0.09, green: 0.10, blue: 0.12, alpha: 0.98).setFill()
            barPath.fill()
            
            // Subtle 1px outer stroke
            NSColor(white: 0.20, alpha: 0.7).setStroke()
            barPath.lineWidth = 1.5
            barPath.stroke()
            
            // 3. Render Buttons
            let buttons = self.getButtons()
            let activePressed = self.pressedButtonId
            
            for btn in buttons {
                let isAppBtn = btn.id.hasPrefix("app_")
                let isFnActive = (btn.id == "fn" && self.currentMode == .fn)
                self.drawButton(btn, isPressed: btn.id == activePressed, isFnActive: isFnActive, isAppSpecific: isAppBtn)
            }
            
            // 4. Mode-specific renderings
            switch self.currentMode {
            case .normal:
                self.drawAppStatusPill()
            case .brightnessSwipe:
                self.drawExpandedBrightnessSlider()
            case .volumeSwipe:
                self.drawExpandedVolumeSlider()
            case .fn:
                break
            }
            
            self.lock.lock()
            self.lastDeliveredTime = Date()
            let pts = CMTime(value: self.frameIndex, timescale: 60)
            self.frameIndex += 1
            self.lock.unlock()
            
            self.encoder?.encode(pixelBuffer: canvas, presentationTime: pts)
        }
    }
    
    // MARK: - Drawing Components
    
    private func drawButton(_ btn: TouchBarButton, isPressed: Bool, isFnActive: Bool, isAppSpecific: Bool = false) {
        let path = NSBezierPath(roundedRect: btn.rect, xRadius: cornerR, yRadius: cornerR)
        
        if isPressed {
            NSColor(white: 0.38, alpha: 1.0).setFill()
        } else if isFnActive {
            NSColor(red: 0.20, green: 0.35, blue: 0.60, alpha: 1.0).setFill()
        } else if isAppSpecific {
            NSColor(red: 0.14, green: 0.18, blue: 0.26, alpha: 1.0).setFill()
        } else if btn.id == "close_swipe" {
            NSColor(red: 0.25, green: 0.15, blue: 0.15, alpha: 1.0).setFill()
        } else {
            NSColor(white: 0.16, alpha: 1.0).setFill()
        }
        path.fill()
        
        // Button border
        if isFnActive {
            NSColor(red: 0.40, green: 0.65, blue: 1.0, alpha: 0.8).setStroke()
            path.lineWidth = 2.0
            path.stroke()
        } else if isAppSpecific {
            NSColor(red: 0.30, green: 0.45, blue: 0.70, alpha: 0.4).setStroke()
            path.lineWidth = 1.0
            path.stroke()
        }
        
        // Icon or Title
        if let sf = btn.sfSymbol, let img = NSImage(systemSymbolName: sf, accessibilityDescription: nil) {
            let conf = NSImage.SymbolConfiguration(pointSize: 32, weight: .semibold)
            let configImg = img.withSymbolConfiguration(conf) ?? img
            let tintImg = configImg.copy() as! NSImage
            tintImg.lockFocus()
            let tint: NSColor
            if isPressed {
                tint = .white
            } else if isAppSpecific {
                tint = NSColor(red: 0.60, green: 0.78, blue: 1.0, alpha: 1.0)
            } else if isFnActive {
                tint = .white
            } else if btn.id == "brightness_icon" {
                tint = NSColor(red: 1.0, green: 0.78, blue: 0.30, alpha: 1.0)
            } else if btn.id == "volume_icon" {
                tint = NSColor(red: 0.45, green: 0.75, blue: 1.0, alpha: 1.0)
            } else {
                tint = NSColor(white: 0.90, alpha: 1.0)
            }
            tint.set()
            NSRect(origin: .zero, size: configImg.size).fill(using: .sourceAtop)
            tintImg.unlockFocus()
            
            let s: CGFloat = 38
            let iconRect = NSRect(
                x: btn.rect.origin.x + (btn.rect.width - s) / 2,
                y: btn.rect.origin.y + (btn.rect.height - s) / 2 + (btn.title.isEmpty ? 0 : 12),
                width: s, height: s
            )
            tintImg.draw(in: iconRect)
            
            // Sub-title if button has both icon and title (e.g. "Bitti")
            if !btn.title.isEmpty {
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                let attr = NSAttributedString(string: btn.title, attributes: [
                    .font: NSFont.systemFont(ofSize: 18, weight: .bold),
                    .foregroundColor: NSColor.white,
                    .paragraphStyle: style
                ])
                let textRect = NSRect(x: btn.rect.origin.x, y: btn.rect.origin.y + 14, width: btn.rect.width, height: 24)
                attr.draw(in: textRect)
            }
            
        } else if !btn.title.isEmpty {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let textColor: NSColor
            if isPressed {
                textColor = .white
            } else if isAppSpecific {
                textColor = NSColor(red: 0.60, green: 0.78, blue: 1.0, alpha: 1.0)
            } else {
                textColor = NSColor(white: 0.92, alpha: 1.0)
            }
            
            let fSize: CGFloat = btn.title.count <= 3 ? 28 : 22
            let attr = NSAttributedString(string: btn.title, attributes: [
                .font: NSFont.systemFont(ofSize: fSize, weight: .semibold),
                .foregroundColor: textColor,
                .paragraphStyle: style
            ])
            let textSize = attr.size()
            let textRect = NSRect(
                x: btn.rect.origin.x,
                y: btn.rect.origin.y + (btn.rect.height - textSize.height) / 2,
                width: btn.rect.width,
                height: textSize.height
            )
            attr.draw(in: textRect)
        }
    }
    
    private func drawAppStatusPill() {
        let hasAppButtons = appConfig?.apps[activeAppBundleId] != nil && !(appConfig?.apps[activeAppBundleId]?.buttons.isEmpty ?? true)
        if hasAppButtons { return }
        
        let pillRect = NSRect(x: 630, y: btnY, width: 630, height: btnH)
        let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: cornerR, yRadius: cornerR)
        NSColor(white: 0.13, alpha: 1.0).setFill()
        pillPath.fill()
        
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let timeStr = formatter.string(from: Date())
        let text = "\(activeAppName)   ·   \(timeStr)"
        
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attr = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 26, weight: .medium),
            .foregroundColor: NSColor(white: 0.75, alpha: 1.0),
            .paragraphStyle: style
        ])
        let textSize = attr.size()
        let textRect = NSRect(
            x: pillRect.origin.x,
            y: pillRect.origin.y + (pillRect.height - textSize.height) / 2,
            width: pillRect.width,
            height: textSize.height
        )
        attr.draw(in: textRect)
    }
    
    private func drawExpandedBrightnessSlider() {
        let rect = brightnessSwipeTrackRect
        let isMoving = activeSlider == "brightness"
        
        // Background card
        let cardPath = NSBezierPath(roundedRect: rect, xRadius: cornerR, yRadius: cornerR)
        NSColor(red: 0.14, green: 0.14, blue: 0.18, alpha: 1.0).setFill()
        cardPath.fill()
        
        // Min icon (left)
        let iconS: CGFloat = 36
        if let img = NSImage(systemSymbolName: "sun.min.fill", accessibilityDescription: nil) {
            let conf = NSImage.SymbolConfiguration(pointSize: 28, weight: .medium)
            let configImg = img.withSymbolConfiguration(conf) ?? img
            let tintImg = configImg.copy() as! NSImage
            tintImg.lockFocus()
            NSColor(red: 1.0, green: 0.78, blue: 0.30, alpha: 0.85).set()
            NSRect(origin: .zero, size: configImg.size).fill(using: .sourceAtop)
            tintImg.unlockFocus()
            let iconRect = NSRect(x: rect.origin.x + 28, y: rect.origin.y + (rect.height - iconS) / 2, width: iconS, height: iconS)
            tintImg.draw(in: iconRect)
        }
        
        // Max icon (right)
        if let img = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil) {
            let conf = NSImage.SymbolConfiguration(pointSize: 28, weight: .bold)
            let configImg = img.withSymbolConfiguration(conf) ?? img
            let tintImg = configImg.copy() as! NSImage
            tintImg.lockFocus()
            NSColor(red: 1.0, green: 0.78, blue: 0.30, alpha: 1.0).set()
            NSRect(origin: .zero, size: configImg.size).fill(using: .sourceAtop)
            tintImg.unlockFocus()
            let iconRect = NSRect(x: rect.origin.x + rect.width - 28 - iconS, y: rect.origin.y + (rect.height - iconS) / 2, width: iconS, height: iconS)
            tintImg.draw(in: iconRect)
        }
        
        // Track
        let trackInsetL: CGFloat = 84
        let trackInsetR: CGFloat = 84
        let trackH: CGFloat = 40
        let trackRect = NSRect(
            x: rect.origin.x + trackInsetL,
            y: rect.origin.y + (rect.height - trackH) / 2,
            width: rect.width - trackInsetL - trackInsetR,
            height: trackH
        )
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: trackH / 2, yRadius: trackH / 2)
        NSColor(white: 0.22, alpha: 1.0).setFill()
        trackPath.fill()
        
        // Fill portion (Amber gradient)
        let fillW = trackRect.width * max(0.02, min(1.0, brightnessLevel))
        let fillRect = NSRect(x: trackRect.origin.x, y: trackRect.origin.y, width: fillW, height: trackH)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: trackH / 2, yRadius: trackH / 2)
        NSColor(red: 1.0, green: 0.76, blue: 0.25, alpha: 1.0).setFill()
        fillPath.fill()
        
        // Thumb Knob
        let thumbR: CGFloat = 28
        let thumbX = trackRect.origin.x + fillW - thumbR
        let thumbY = trackRect.origin.y + trackH / 2 - thumbR
        let thumbRect = NSRect(x: thumbX, y: thumbY, width: thumbR * 2, height: thumbR * 2)
        let thumbPath = NSBezierPath(ovalIn: thumbRect)
        NSColor.white.setFill()
        thumbPath.fill()
        if isMoving {
            NSColor(red: 1.0, green: 0.90, blue: 0.60, alpha: 0.6).setStroke()
            thumbPath.lineWidth = 4.0
            thumbPath.stroke()
        }
        
        // Percentage badge in center
        let pctText = "☀️ Parlaklık: %\(Int(brightnessLevel * 100))"
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attr = NSAttributedString(string: pctText, attributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style
        ])
        let textRect = NSRect(x: rect.origin.x, y: rect.origin.y + rect.height - 38, width: rect.width, height: 28)
        attr.draw(in: textRect)
    }
    
    private func drawExpandedVolumeSlider() {
        let rect = volumeSwipeTrackRect
        let isMoving = activeSlider == "volume"
        
        // Background card
        let cardPath = NSBezierPath(roundedRect: rect, xRadius: cornerR, yRadius: cornerR)
        NSColor(red: 0.13, green: 0.15, blue: 0.19, alpha: 1.0).setFill()
        cardPath.fill()
        
        // Min icon (left)
        let iconS: CGFloat = 36
        if let img = NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: nil) {
            let conf = NSImage.SymbolConfiguration(pointSize: 28, weight: .medium)
            let configImg = img.withSymbolConfiguration(conf) ?? img
            let tintImg = configImg.copy() as! NSImage
            tintImg.lockFocus()
            NSColor(red: 0.45, green: 0.75, blue: 1.0, alpha: 0.85).set()
            NSRect(origin: .zero, size: configImg.size).fill(using: .sourceAtop)
            tintImg.unlockFocus()
            let iconRect = NSRect(x: rect.origin.x + 28, y: rect.origin.y + (rect.height - iconS) / 2, width: iconS, height: iconS)
            tintImg.draw(in: iconRect)
        }
        
        // Max icon (right)
        if let img = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil) {
            let conf = NSImage.SymbolConfiguration(pointSize: 28, weight: .bold)
            let configImg = img.withSymbolConfiguration(conf) ?? img
            let tintImg = configImg.copy() as! NSImage
            tintImg.lockFocus()
            NSColor(red: 0.45, green: 0.75, blue: 1.0, alpha: 1.0).set()
            NSRect(origin: .zero, size: configImg.size).fill(using: .sourceAtop)
            tintImg.unlockFocus()
            let iconRect = NSRect(x: rect.origin.x + rect.width - 28 - iconS, y: rect.origin.y + (rect.height - iconS) / 2, width: iconS, height: iconS)
            tintImg.draw(in: iconRect)
        }
        
        // Track
        let trackInsetL: CGFloat = 84
        let trackInsetR: CGFloat = 84
        let trackH: CGFloat = 40
        let trackRect = NSRect(
            x: rect.origin.x + trackInsetL,
            y: rect.origin.y + (rect.height - trackH) / 2,
            width: rect.width - trackInsetL - trackInsetR,
            height: trackH
        )
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: trackH / 2, yRadius: trackH / 2)
        NSColor(white: 0.22, alpha: 1.0).setFill()
        trackPath.fill()
        
        // Fill portion (Blue gradient)
        let fillW = trackRect.width * max(0.02, min(1.0, volumeLevel))
        let fillRect = NSRect(x: trackRect.origin.x, y: trackRect.origin.y, width: fillW, height: trackH)
        let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: trackH / 2, yRadius: trackH / 2)
        NSColor(red: 0.35, green: 0.65, blue: 1.0, alpha: 1.0).setFill()
        fillPath.fill()
        
        // Thumb Knob
        let thumbR: CGFloat = 28
        let thumbX = trackRect.origin.x + fillW - thumbR
        let thumbY = trackRect.origin.y + trackH / 2 - thumbR
        let thumbRect = NSRect(x: thumbX, y: thumbY, width: thumbR * 2, height: thumbR * 2)
        let thumbPath = NSBezierPath(ovalIn: thumbRect)
        NSColor.white.setFill()
        thumbPath.fill()
        if isMoving {
            NSColor(red: 0.60, green: 0.85, blue: 1.0, alpha: 0.6).setStroke()
            thumbPath.lineWidth = 4.0
            thumbPath.stroke()
        }
        
        // Percentage badge in center
        let pctText = "🔊 Ses: %\(Int(volumeLevel * 100))"
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attr = NSAttributedString(string: pctText, attributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style
        ])
        let textRect = NSRect(x: rect.origin.x, y: rect.origin.y + rect.height - 38, width: rect.width, height: 28)
        attr.draw(in: textRect)
    }
    
    // MARK: - Keepalive
    
    private func startKeepalive() {
        keepaliveTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(33), repeating: .milliseconds(33))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let now = Date()
            self.lock.lock()
            let elapsed = now.timeIntervalSince(self.lastDeliveredTime)
            self.lock.unlock()
            if elapsed >= 0.080 {
                self.renderAndEncode()
            }
        }
        timer.resume()
        self.keepaliveTimer = timer
    }
    
    // MARK: - Touch Handling
    
    private func handleTouch(type: UInt8, normX: Float, normY: Float) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            let canvasX = CGFloat(normX) * CGFloat(self.canvasWidth)
            let canvasY = (1.0 - CGFloat(normY)) * CGFloat(self.canvasHeight)
            let touchPoint = CGPoint(x: canvasX, y: canvasY)
            
            // Generous vertical hit-test tolerance for mobile touch (covers the whole bar vertically)
            let isVerticallyInBar = (canvasY >= 0 && canvasY <= CGFloat(self.canvasHeight))
            
            if type == 1 {
                // ACTION_DOWN
                if self.currentMode == .brightnessSwipe {
                    let track = self.brightnessSwipeTrackRect
                    // Check close button on left
                    if canvasX < track.minX && isVerticallyInBar {
                        self.lock.lock()
                        self.currentMode = .normal
                        self.activeSlider = nil
                        self.lock.unlock()
                        self.renderAndEncode()
                        return
                    }
                    if isVerticallyInBar && canvasX >= track.minX && canvasX <= track.maxX {
                        self.activeSlider = "brightness"
                        self.updateSliderValue(canvasX: canvasX, slider: "brightness")
                        self.resetAutoCollapseTimer(delay: 5.0)
                        self.renderAndEncode()
                        return
                    }
                } else if self.currentMode == .volumeSwipe {
                    let track = self.volumeSwipeTrackRect
                    // Check close button on left
                    if canvasX < track.minX && isVerticallyInBar {
                        self.lock.lock()
                        self.currentMode = .normal
                        self.activeSlider = nil
                        self.lock.unlock()
                        self.renderAndEncode()
                        return
                    }
                    // Check mute button on right
                    if canvasX > track.maxX && isVerticallyInBar {
                        toggleSystemMute()
                        self.renderAndEncode()
                        return
                    }
                    if isVerticallyInBar && canvasX >= track.minX && canvasX <= track.maxX {
                        self.activeSlider = "volume"
                        self.updateSliderValue(canvasX: canvasX, slider: "volume")
                        self.resetAutoCollapseTimer(delay: 5.0)
                        self.renderAndEncode()
                        return
                    }
                }
                
                let buttons = self.getButtons()
                if isVerticallyInBar {
                    // Match button by X column with generous tolerance and proximity margin
                    let margin: CGFloat = 16.0
                    if let btn = buttons.first(where: { canvasX >= ($0.rect.minX - margin) && canvasX <= ($0.rect.maxX + margin) }) {
                        self.pressedButtonId = btn.id
                        btn.action()
                        self.renderAndEncode()
                        return
                    }
                }
                
            } else if type == 2 {
                // ACTION_MOVE
                if let slider = self.activeSlider {
                    self.updateSliderValue(canvasX: canvasX, slider: slider)
                    self.resetAutoCollapseTimer(delay: 5.0)
                    self.renderAndEncode()
                    return
                }
                
            } else if type == 3 {
                // ACTION_UP
                self.activeSlider = nil
                if self.pressedButtonId != nil {
                    self.pressedButtonId = nil
                    self.renderAndEncode()
                }
                if self.currentMode == .brightnessSwipe || self.currentMode == .volumeSwipe {
                    self.resetAutoCollapseTimer(delay: 3.0)
                }
            }
        }
    }
    
    private func updateSliderValue(canvasX: CGFloat, slider: String) {
        let isBrightness = (slider == "brightness")
        let rect = isBrightness ? brightnessSwipeTrackRect : volumeSwipeTrackRect
        let trackInsetL: CGFloat = 84
        let trackInsetR: CGFloat = 84
        let trackStart = rect.origin.x + trackInsetL
        let trackWidth = rect.width - trackInsetL - trackInsetR
        
        let newLevel = max(0.0, min(1.0, (canvasX - trackStart) / trackWidth))
        
        if isBrightness {
            brightnessLevel = newLevel
            VDBridgeSetBrightness(Float(newLevel))
        } else {
            volumeLevel = newLevel
            setSystemVolume(Float(newLevel))
        }
    }
}

// MARK: - CoreAudio Volume Helpers

private func getSystemVolume() -> Float {
    var defaultOutputDeviceID = AudioDeviceID(0)
    var defaultOutputDeviceIDSize = UInt32(MemoryLayout.size(ofValue: defaultOutputDeviceID))
    var getDefaultOutputDevicePropertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &getDefaultOutputDevicePropertyAddress,
        0,
        nil,
        &defaultOutputDeviceIDSize,
        &defaultOutputDeviceID
    )
    guard status == noErr else { return 0.5 }

    var volumePropertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var vol: Float = 0.5
    var size = UInt32(MemoryLayout.size(ofValue: vol))
    AudioObjectGetPropertyData(defaultOutputDeviceID, &volumePropertyAddress, 0, nil, &size, &vol)
    return max(0.0, min(1.0, vol))
}

private func setSystemVolume(_ level: Float) {
    var defaultOutputDeviceID = AudioDeviceID(0)
    var defaultOutputDeviceIDSize = UInt32(MemoryLayout.size(ofValue: defaultOutputDeviceID))
    var getDefaultOutputDevicePropertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &getDefaultOutputDevicePropertyAddress,
        0,
        nil,
        &defaultOutputDeviceIDSize,
        &defaultOutputDeviceID
    )
    guard status == noErr else { return }

    var volumePropertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var vol = max(0.0, min(1.0, level))
    AudioObjectSetPropertyData(
        defaultOutputDeviceID,
        &volumePropertyAddress,
        0,
        nil,
        UInt32(MemoryLayout.size(ofValue: vol)),
        &vol
    )
}

private func toggleSystemMute() {
    var defaultOutputDeviceID = AudioDeviceID(0)
    var defaultOutputDeviceIDSize = UInt32(MemoryLayout.size(ofValue: defaultOutputDeviceID))
    var getDefaultOutputDevicePropertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &getDefaultOutputDevicePropertyAddress,
        0,
        nil,
        &defaultOutputDeviceIDSize,
        &defaultOutputDeviceID
    )
    guard status == noErr else { return }

    var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    var isMuted: UInt32 = 0
    var size = UInt32(MemoryLayout.size(ofValue: isMuted))
    AudioObjectGetPropertyData(defaultOutputDeviceID, &muteAddress, 0, nil, &size, &isMuted)
    isMuted = (isMuted == 0) ? 1 : 0
    AudioObjectSetPropertyData(defaultOutputDeviceID, &muteAddress, 0, nil, size, &isMuted)
}
