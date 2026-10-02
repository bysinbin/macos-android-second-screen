import Foundation
import CoreGraphics
import AppKit

public final class TouchInjector: @unchecked Sendable {
    private var displayID: CGDirectDisplayID
    private let queue = DispatchQueue(label: "com.antigravity.touchinjector")
    private var isLeftMouseDown: Bool = false
    private var currentCursorPos: CGPoint = .zero
    
    // Direct touch tracking to avoid micro-jitter canceling clicks
    private var touchStartPoint: CGPoint = .zero
    private var isTouchDragging: Bool = false
    private var isTouchActive: Bool = false
    
    // Tap to click multi-click detection
    private var lastClickTime: TimeInterval = 0
    private var clickCount: Int64 = 1
    
    public init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }
    
    public func updateDisplayID(_ displayID: CGDirectDisplayID) {
        queue.async {
            self.displayID = displayID
        }
    }
    
    public func handleTouchEvent(type: UInt8, normX: Float, normY: Float, deltaY: Float = 0.0) {
        queue.async {
            var targetDisplay = self.displayID
            if targetDisplay == 0 {
                targetDisplay = CGMainDisplayID()
            }
            let bounds = CGDisplayBounds(targetDisplay)
            guard bounds.width > 0 && bounds.height > 0 else { return }
            
            if self.currentCursorPos == .zero || !bounds.contains(self.currentCursorPos) {
                self.currentCursorPos = CGEvent(source: nil)?.location ?? CGPoint(x: bounds.midX, y: bounds.midY)
            }
            
            switch type {
            // MARK: - Direct Touch: Down
            case ScreenProtocol.ClientPacketType.touchDown.rawValue:
                let clampedX = CGFloat(max(0.0, min(1.0, normX)))
                let clampedY = CGFloat(max(0.0, min(1.0, normY)))
                let targetPoint = CGPoint(x: bounds.origin.x + clampedX * bounds.width, y: bounds.origin.y + clampedY * bounds.height)
                
                self.touchStartPoint = targetPoint
                self.isTouchDragging = false
                self.isTouchActive = true
                self.isLeftMouseDown = true
                self.currentCursorPos = targetPoint
                
                CGWarpMouseCursorPosition(targetPoint)
                if let downEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: targetPoint, mouseButton: .left) {
                    downEvent.setIntegerValueField(.mouseEventClickState, value: 1)
                    downEvent.post(tap: .cghidEventTap)
                }
                
            // MARK: - Direct Touch: Move
            case ScreenProtocol.ClientPacketType.touchMove.rawValue:
                guard self.isTouchActive else { return }
                let clampedX = CGFloat(max(0.0, min(1.0, normX)))
                let clampedY = CGFloat(max(0.0, min(1.0, normY)))
                let targetPoint = CGPoint(x: bounds.origin.x + clampedX * bounds.width, y: bounds.origin.y + clampedY * bounds.height)
                self.currentCursorPos = targetPoint
                
                let dist = hypot(targetPoint.x - self.touchStartPoint.x, targetPoint.y - self.touchStartPoint.y)
                if dist > 8.0 || self.isTouchDragging {
                    self.isTouchDragging = true
                    CGWarpMouseCursorPosition(targetPoint)
                    if let dragEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: targetPoint, mouseButton: .left) {
                        dragEvent.setIntegerValueField(.mouseEventClickState, value: 1)
                        dragEvent.post(tap: .cghidEventTap)
                    }
                }
                
            // MARK: - Direct Touch: Up
            case ScreenProtocol.ClientPacketType.touchUp.rawValue:
                let wasDragging = self.isTouchDragging
                self.isTouchActive = false
                self.isTouchDragging = false
                self.isLeftMouseDown = false
                
                let clampedX = CGFloat(max(0.0, min(1.0, normX)))
                let clampedY = CGFloat(max(0.0, min(1.0, normY)))
                let targetPoint = CGPoint(x: bounds.origin.x + clampedX * bounds.width, y: bounds.origin.y + clampedY * bounds.height)
                self.currentCursorPos = targetPoint
                
                if !wasDragging {
                    // Tap: release cleanly at touchStartPoint with clickState 1
                    CGWarpMouseCursorPosition(self.touchStartPoint)
                    usleep(15000)
                    if let upEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: self.touchStartPoint, mouseButton: .left) {
                        upEvent.setIntegerValueField(.mouseEventClickState, value: 1)
                        upEvent.post(tap: .cghidEventTap)
                    }
                    if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: self.touchStartPoint, mouseButton: .left) {
                        moveEvent.post(tap: .cghidEventTap)
                    }
                } else {
                    // Drag: release at current position with clickState 1
                    CGWarpMouseCursorPosition(targetPoint)
                    if let upEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: targetPoint, mouseButton: .left) {
                        upEvent.setIntegerValueField(.mouseEventClickState, value: 1)
                        upEvent.post(tap: .cghidEventTap)
                    }
                    if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: targetPoint, mouseButton: .left) {
                        moveEvent.post(tap: .cghidEventTap)
                    }
                }
                
            // MARK: - Mouse Down (0x0B)
            case ScreenProtocol.ClientPacketType.mouseDown.rawValue:
                let curPos = CGEvent(source: nil)?.location ?? self.currentCursorPos
                self.isLeftMouseDown = true
                let src = CGEventSource(stateID: .hidSystemState)
                if let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: curPos, mouseButton: .left) {
                    down.setIntegerValueField(.mouseEventClickState, value: 1)
                    down.post(tap: .cghidEventTap)
                }
                
            // MARK: - Mouse Up (0x0C)
            case ScreenProtocol.ClientPacketType.mouseUp.rawValue:
                let curPos = CGEvent(source: nil)?.location ?? self.currentCursorPos
                self.isLeftMouseDown = false
                let src = CGEventSource(stateID: .hidSystemState)
                if let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: curPos, mouseButton: .left) {
                    up.setIntegerValueField(.mouseEventClickState, value: 1)
                    up.post(tap: .cghidEventTap)
                }
                if let moveEvent = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: curPos, mouseButton: .left) {
                    moveEvent.post(tap: .cghidEventTap)
                }
                
            // MARK: - Relative Drag (0x0A) - used when dragging / selecting
            case ScreenProtocol.ClientPacketType.mouseRelativeDrag.rawValue:
                let curPos = CGEvent(source: nil)?.location ?? self.currentCursorPos
                let src = CGEventSource(stateID: .hidSystemState)
                if !self.isLeftMouseDown {
                    self.isLeftMouseDown = true
                    if let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: curPos, mouseButton: .left) {
                        down.setIntegerValueField(.mouseEventClickState, value: 1)
                        down.post(tap: .cghidEventTap)
                    }
                }
                let sensitivity: CGFloat = 1.8
                let scaleW = max(bounds.width, 1920.0)
                let scaleH = max(bounds.height, 1080.0)
                let newX = max(bounds.minX, min(bounds.maxX - 1, curPos.x + CGFloat(normX) * scaleW * sensitivity))
                let newY = max(bounds.minY, min(bounds.maxY - 1, curPos.y + CGFloat(normY) * scaleH * sensitivity))
                let targetPoint = CGPoint(x: newX, y: newY)
                self.currentCursorPos = targetPoint
                
                CGWarpMouseCursorPosition(targetPoint)
                if let dragEvent = CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged, mouseCursorPosition: targetPoint, mouseButton: .left) {
                    dragEvent.setIntegerValueField(.mouseEventClickState, value: 1)
                    dragEvent.post(tap: .cghidEventTap)
                }
                
            // MARK: - Relative Move (0x07) - used for normal cursor move
            case ScreenProtocol.ClientPacketType.mouseRelativeMove.rawValue:
                let curPos = CGEvent(source: nil)?.location ?? self.currentCursorPos
                let sensitivity: CGFloat = 1.8
                let scaleW = max(bounds.width, 1920.0)
                let scaleH = max(bounds.height, 1080.0)
                let newX = max(bounds.minX, min(bounds.maxX - 1, curPos.x + CGFloat(normX) * scaleW * sensitivity))
                let newY = max(bounds.minY, min(bounds.maxY - 1, curPos.y + CGFloat(normY) * scaleH * sensitivity))
                let targetPoint = CGPoint(x: newX, y: newY)
                self.currentCursorPos = targetPoint
                
                CGWarpMouseCursorPosition(targetPoint)
                let src = CGEventSource(stateID: .hidSystemState)
                if self.isLeftMouseDown {
                    if let dragEvent = CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged, mouseCursorPosition: targetPoint, mouseButton: .left) {
                        dragEvent.setIntegerValueField(.mouseEventClickState, value: 1)
                        dragEvent.post(tap: .cghidEventTap)
                    }
                } else {
                    if let moveEvent = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: targetPoint, mouseButton: .left) {
                        moveEvent.post(tap: .cghidEventTap)
                    }
                }
                
            // MARK: - Tap Click (0x08)
            case ScreenProtocol.ClientPacketType.mouseClick.rawValue:
                let curPos = CGEvent(source: nil)?.location ?? self.currentCursorPos
                self.isLeftMouseDown = false
                
                let now = Date().timeIntervalSince1970
                if now - self.lastClickTime < 0.35 {
                    self.clickCount = min(3, self.clickCount + 1)
                } else {
                    self.clickCount = 1
                }
                self.lastClickTime = now
                
                let src = CGEventSource(stateID: .hidSystemState)
                if let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: curPos, mouseButton: .left) {
                    down.setIntegerValueField(.mouseEventClickState, value: self.clickCount)
                    down.post(tap: .cghidEventTap)
                }
                usleep(25000)
                if let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: curPos, mouseButton: .left) {
                    up.setIntegerValueField(.mouseEventClickState, value: self.clickCount)
                    up.post(tap: .cghidEventTap)
                }
                
            // MARK: - Two-finger Right Click (0x09)
            case ScreenProtocol.ClientPacketType.mouseRightClick.rawValue:
                let curPos = CGEvent(source: nil)?.location ?? self.currentCursorPos
                let src = CGEventSource(stateID: .hidSystemState)
                if let rightDown = CGEvent(mouseEventSource: src, mouseType: .rightMouseDown, mouseCursorPosition: curPos, mouseButton: .right) {
                    rightDown.setIntegerValueField(.mouseEventClickState, value: 1)
                    rightDown.post(tap: .cghidEventTap)
                }
                usleep(25000)
                if let rightUp = CGEvent(mouseEventSource: src, mouseType: .rightMouseUp, mouseCursorPosition: curPos, mouseButton: .right) {
                    rightUp.setIntegerValueField(.mouseEventClickState, value: 1)
                    rightUp.post(tap: .cghidEventTap)
                }
                
            // MARK: - Scroll (0x05)
            case ScreenProtocol.ClientPacketType.scroll.rawValue:
                let curPos = CGEvent(source: nil)?.location ?? self.currentCursorPos
                let scrollY = Int32(round(deltaY * 2.0))
                let scrollX = Int32(round(normX * 2.0))
                if scrollY != 0 || scrollX != 0 {
                    if let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: scrollY, wheel2: scrollX, wheel3: 0) {
                        scrollEvent.location = curPos
                        scrollEvent.post(tap: .cghidEventTap)
                    }
                }
                
            // MARK: - 3-Finger Gestures (0x0D)
            case ScreenProtocol.ClientPacketType.gestureAction.rawValue:
                NSLog("[TouchInjector] 3-Finger Gesture: normX=\(normX), normY=\(normY)")
                if normY < -0.3 {
                    // Swipe Up -> Mission Control
                    self.triggerMissionControl()
                } else if normY > 0.3 {
                    // Swipe Down -> App Exposé
                    self.triggerAppExpose()
                } else if normX < -0.3 {
                    // Swipe Left -> Move Space Right
                    self.triggerSpaceRight()
                } else if normX > 0.3 {
                    // Swipe Right -> Move Space Left
                    self.triggerSpaceLeft()
                } else {
                    // 3-Finger Tap -> Dictionary / Look Up
                    self.triggerLookUp()
                }
                
            default:
                break
            }
        }
    }
    
    // MARK: - System Gestures
    
    private func triggerMissionControl() {
        self.postKeyWithFlags(keyCode: 126, flags: .maskControl)
        self.runProcess("/usr/bin/open", ["-a", "Mission Control"])
    }
    
    private func triggerAppExpose() {
        self.postKeyWithFlags(keyCode: 125, flags: .maskControl)
        self.runAppleScriptCmd("tell application \"System Events\" to key code 125 using {control down}")
    }
    
    private func triggerSpaceRight() {
        self.postKeyWithFlags(keyCode: 124, flags: .maskControl)
        self.runAppleScriptCmd("tell application \"System Events\" to key code 124 using {control down}")
    }
    
    private func triggerSpaceLeft() {
        self.postKeyWithFlags(keyCode: 123, flags: .maskControl)
        self.runAppleScriptCmd("tell application \"System Events\" to key code 123 using {control down}")
    }
    
    private func triggerLookUp() {
        self.postKeyWithFlags(keyCode: 2, flags: [.maskCommand, .maskControl]) // 'd' key = 2
        self.runAppleScriptCmd("tell application \"System Events\" to keystroke \"d\" using {command down, control down}")
    }
    
    private func runProcess(_ path: String, _ args: [String]) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            try? p.run()
        }
    }
    
    private func runAppleScriptCmd(_ scriptText: String) {
        self.runProcess("/usr/bin/osascript", ["-e", scriptText])
    }
    
    private func postKeyWithFlags(keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        let hasControl = flags.contains(.maskControl)
        let hasCommand = flags.contains(.maskCommand)
        let hasShift = flags.contains(.maskShift)
        let hasOption = flags.contains(.maskAlternate)

        // 1. Modifiers down
        if hasControl, let cDown = CGEvent(keyboardEventSource: src, virtualKey: 59, keyDown: true) { // Left Control
            cDown.flags = .maskControl
            cDown.post(tap: .cghidEventTap)
            cDown.post(tap: .cgSessionEventTap)
        }
        if hasCommand, let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: 55, keyDown: true) { // Left Command
            cmdDown.flags = flags
            cmdDown.post(tap: .cghidEventTap)
            cmdDown.post(tap: .cgSessionEventTap)
        }
        usleep(15000)

        // 2. Key down & up
        if let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
            down.post(tap: .cgSessionEventTap)
        }
        usleep(30000)
        if let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
            up.post(tap: .cgSessionEventTap)
        }
        usleep(15000)

        // 3. Modifiers up
        if hasCommand, let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: 55, keyDown: false) {
            cmdUp.post(tap: .cghidEventTap)
            cmdUp.post(tap: .cgSessionEventTap)
        }
        if hasControl, let cUp = CGEvent(keyboardEventSource: src, virtualKey: 59, keyDown: false) {
            cUp.post(tap: .cghidEventTap)
            cUp.post(tap: .cgSessionEventTap)
        }
    }
}
