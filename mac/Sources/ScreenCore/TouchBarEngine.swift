import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Cocoa
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
    
    // Canvas dimensions (2016x128 fits standard Touch Bar aspect ratio, multiples of 16 for H.264)
    public let canvasWidth: Int = 2016
    public let canvasHeight: Int = 128
    
    // Dynamic Touch Bar State
    private var isFnMode: Bool = false
    private var pressedButtonId: String? = nil
    private var activeAppName: String = "Mac"
    private var lastAppUpdateTime = Date.distantPast
    
    private struct TouchBarButton {
        let id: String
        let rect: NSRect
        let title: String
        let sfSymbol: String?
        let action: @Sendable () -> Void
    }
    
    public init() {}
    
    public func start(port: UInt16 = ScreenProtocol.touchBarPort) throws {
        guard !isRunning else { return }
        
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
            self?.renderAndEncode()
            self?.onClientConnected?()
        }
        
        netServer.onTouchEvent = { [weak self] type, normX, normY, _ in
            self?.handleTouch(type: type, normX: normX, normY: normY)
        }
        
        try netServer.start(width: UInt32(canvasWidth), height: UInt32(canvasHeight), fps: 60)
        
        // Initial render of the Touch Bar canvas
        renderAndEncode()
        startKeepalive()
        
        self.isRunning = true
        onStatusChanged?("🪄 Apple Touch Bar Yayında (Port \(port))")
    }
    
    public func stop() {
        guard isRunning else { return }
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
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
    
    private func getButtons() -> [TouchBarButton] {
        var buttons = [TouchBarButton]()
        
        // 1. Always present: Esc & Fn
        buttons.append(TouchBarButton(id: "esc", rect: NSRect(x: 20, y: 16, width: 130, height: 96), title: "⎋ esc", sfSymbol: nil) {
            VDBridgePostVirtualKey(0x35, true)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                VDBridgePostVirtualKey(0x35, false)
            }
        })
        
        buttons.append(TouchBarButton(id: "fn", rect: NSRect(x: 162, y: 16, width: 90, height: 96), title: "fn", sfSymbol: nil) { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.isFnMode.toggle()
            self.lock.unlock()
        })
        
        if isFnMode {
            // F1 - F12 keys
            let fKeys: [(String, UInt16)] = [
                ("F1", 0x7A), ("F2", 0x78), ("F3", 0x63), ("F4", 0x76),
                ("F5", 0x60), ("F6", 0x61), ("F7", 0x62), ("F8", 0x64),
                ("F9", 0x65), ("F10", 0x6D), ("F11", 0x67), ("F12", 0x6F)
            ]
            let startX: CGFloat = 266
            let btnW: CGFloat = 138
            let spacing: CGFloat = 8
            
            for (idx, (name, keyCode)) in fKeys.enumerated() {
                let x = startX + CGFloat(idx) * (btnW + spacing)
                buttons.append(TouchBarButton(id: name.lowercased(), rect: NSRect(x: x, y: 16, width: btnW, height: 96), title: name, sfSymbol: nil) {
                    VDBridgePostVirtualKey(keyCode, true)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                        VDBridgePostVirtualKey(keyCode, false)
                    }
                })
            }
        } else {
            // Normal Apple Touch Bar Mode
            // 2. Quick Actions
            buttons.append(TouchBarButton(id: "search", rect: NSRect(x: 264, y: 16, width: 86, height: 96), title: "", sfSymbol: "magnifyingglass") {
                // Cmd + Space for Spotlight
                let src = CGEventSource(stateID: .hidSystemState)
                let down = CGEvent(keyboardEventSource: src, virtualKey: 0x31, keyDown: true)
                down?.flags = .maskCommand
                let up = CGEvent(keyboardEventSource: src, virtualKey: 0x31, keyDown: false)
                down?.post(tap: .cghidEventTap)
                up?.post(tap: .cghidEventTap)
            })
            
            buttons.append(TouchBarButton(id: "screenshot", rect: NSRect(x: 360, y: 16, width: 86, height: 96), title: "", sfSymbol: "camera.fill") {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-c"]
                try? p.run()
            })
            
            buttons.append(TouchBarButton(id: "lock", rect: NSRect(x: 456, y: 16, width: 86, height: 96), title: "", sfSymbol: "lock.fill") {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
                p.arguments = ["displaysleepnow"]
                try? p.run()
            })
            
            // 3. Media Controls
            buttons.append(TouchBarButton(id: "prev", rect: NSRect(x: 580, y: 16, width: 86, height: 96), title: "", sfSymbol: "backward.fill") {
                VDBridgePostSystemMediaKey(18) // NX_KEYTYPE_PREVIOUS
            })
            
            buttons.append(TouchBarButton(id: "play", rect: NSRect(x: 676, y: 16, width: 96, height: 96), title: "", sfSymbol: "playpause.fill") {
                VDBridgePostSystemMediaKey(16) // NX_KEYTYPE_PLAY
            })
            
            buttons.append(TouchBarButton(id: "next", rect: NSRect(x: 782, y: 16, width: 86, height: 96), title: "", sfSymbol: "forward.fill") {
                VDBridgePostSystemMediaKey(17) // NX_KEYTYPE_NEXT
            })
            
            // 4. System Control Strip (Right side)
            buttons.append(TouchBarButton(id: "bright_down", rect: NSRect(x: 1324, y: 16, width: 86, height: 96), title: "", sfSymbol: "sun.min.fill") {
                VDBridgePostSystemMediaKey(3) // NX_KEYTYPE_BRIGHTNESS_DOWN
            })
            
            buttons.append(TouchBarButton(id: "bright_up", rect: NSRect(x: 1420, y: 16, width: 86, height: 96), title: "", sfSymbol: "sun.max.fill") {
                VDBridgePostSystemMediaKey(2) // NX_KEYTYPE_BRIGHTNESS_UP
            })
            
            buttons.append(TouchBarButton(id: "mission", rect: NSRect(x: 1516, y: 16, width: 86, height: 96), title: "", sfSymbol: "rectangle.3.group.fill") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
            })
            
            buttons.append(TouchBarButton(id: "launchpad", rect: NSRect(x: 1612, y: 16, width: 86, height: 96), title: "", sfSymbol: "circle.grid.3x3.fill") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Launchpad.app"))
            })
            
            buttons.append(TouchBarButton(id: "mute", rect: NSRect(x: 1708, y: 16, width: 86, height: 96), title: "", sfSymbol: "speaker.slash.fill") {
                VDBridgePostSystemMediaKey(7) // NX_KEYTYPE_MUTE
            })
            
            buttons.append(TouchBarButton(id: "vol_down", rect: NSRect(x: 1804, y: 16, width: 92, height: 96), title: "", sfSymbol: "speaker.wave.1.fill") {
                VDBridgePostSystemMediaKey(1) // NX_KEYTYPE_SOUND_DOWN
            })
            
            buttons.append(TouchBarButton(id: "vol_up", rect: NSRect(x: 1906, y: 16, width: 92, height: 96), title: "", sfSymbol: "speaker.wave.3.fill") {
                VDBridgePostSystemMediaKey(0) // NX_KEYTYPE_SOUND_UP
            })
        }
        
        return buttons
    }
    
    private func renderAndEncode() {
        queue.async { [weak self] in
            guard let self = self, let canvas = self.canvasBuffer else { return }
            
            // Check frontmost app periodically
            if Date().timeIntervalSince(self.lastAppUpdateTime) > 1.5 {
                self.lastAppUpdateTime = Date()
                if let app = NSWorkspace.shared.frontmostApplication?.localizedName {
                    self.activeAppName = app
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
            
            // Deep OLED black background
            ctx.setFillColor(CGColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1.0))
            ctx.fill(CGRect(x: 0, y: 0, width: self.canvasWidth, height: self.canvasHeight))
            
            let buttons = self.getButtons()
            let activePressed = self.pressedButtonId
            
            for btn in buttons {
                let isPressed = (btn.id == activePressed)
                let isFnActive = (btn.id == "fn" && self.isFnMode)
                
                let path = NSBezierPath(roundedRect: btn.rect, xRadius: 18, yRadius: 18)
                
                if isPressed {
                    NSColor(red: 0.0, green: 0.82, blue: 1.0, alpha: 0.35).setFill()
                    path.fill()
                    NSColor(red: 0.0, green: 0.82, blue: 1.0, alpha: 0.9).setStroke()
                    path.lineWidth = 3.0
                    path.stroke()
                } else if isFnActive {
                    NSColor(red: 0.25, green: 0.25, blue: 0.35, alpha: 1.0).setFill()
                    path.fill()
                    NSColor(red: 0.0, green: 0.82, blue: 1.0, alpha: 0.7).setStroke()
                    path.lineWidth = 2.0
                    path.stroke()
                } else {
                    NSColor(red: 0.16, green: 0.16, blue: 0.18, alpha: 1.0).setFill()
                    path.fill()
                    NSColor(red: 0.26, green: 0.26, blue: 0.28, alpha: 1.0).setStroke()
                    path.lineWidth = 1.5
                    path.stroke()
                }
                
                if let sf = btn.sfSymbol, let img = NSImage(systemSymbolName: sf, accessibilityDescription: nil) {
                    let tintImg = img.copy() as! NSImage
                    tintImg.lockFocus()
                    if isPressed || isFnActive {
                        NSColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 1.0).set()
                    } else {
                        NSColor(white: 0.92, alpha: 1.0).set()
                    }
                    NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
                    tintImg.unlockFocus()
                    
                    let iconSize: CGFloat = 42
                    let iconRect = NSRect(
                        x: btn.rect.origin.x + (btn.rect.width - iconSize) / 2,
                        y: btn.rect.origin.y + (btn.rect.height - iconSize) / 2,
                        width: iconSize,
                        height: iconSize
                    )
                    tintImg.draw(in: iconRect)
                } else {
                    let style = NSMutableParagraphStyle()
                    style.alignment = .center
                    let textColor = (isPressed || isFnActive) ? NSColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 1.0) : NSColor.white
                    let attr = NSAttributedString(string: btn.title, attributes: [
                        .font: NSFont.systemFont(ofSize: 26, weight: .semibold),
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
            
            // Draw Center Status Pill in Normal Mode
            if !self.isFnMode {
                let pillRect = NSRect(x: 888, y: 16, width: 416, height: 96)
                let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 20, yRadius: 20)
                NSColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1.0).setFill()
                pillPath.fill()
                NSColor(red: 0.22, green: 0.22, blue: 0.24, alpha: 1.0).setStroke()
                pillPath.lineWidth = 1.0
                pillPath.stroke()
                
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm"
                let timeStr = formatter.string(from: Date())
                
                let text = "\(self.activeAppName)  •  \(timeStr)"
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                let attr = NSAttributedString(string: text, attributes: [
                    .font: NSFont.systemFont(ofSize: 24, weight: .medium),
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
            self.lock.unlock()
            
            // Re-render at least once every 100ms or when state changes
            if elapsed >= 0.080 {
                self.renderAndEncode()
            }
        }
        timer.resume()
        self.keepaliveTimer = timer
    }
    
    private func handleTouch(type: UInt8, normX: Float, normY: Float) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            let canvasX = CGFloat(normX) * CGFloat(self.canvasWidth)
            // Flip Y: Touch coordinates (0=top, 1=bottom) to AppKit (0=bottom, height=top)
            let canvasY = (1.0 - CGFloat(normY)) * CGFloat(self.canvasHeight)
            let touchPoint = CGPoint(x: canvasX, y: canvasY)
            
            let buttons = self.getButtons()
            let hitBtn = buttons.first { $0.rect.contains(touchPoint) }
            
            if type == 1 {
                // ACTION_DOWN
                if let btn = hitBtn {
                    self.pressedButtonId = btn.id
                    btn.action()
                    self.renderAndEncode()
                }
            } else if type == 2 {
                // ACTION_MOVE
                let newId = hitBtn?.id
                if newId != self.pressedButtonId {
                    self.pressedButtonId = newId
                    self.renderAndEncode()
                }
            } else if type == 3 {
                // ACTION_UP / CANCEL
                if self.pressedButtonId != nil {
                    self.pressedButtonId = nil
                    self.renderAndEncode()
                }
            }
        }
    }
}
