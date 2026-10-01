import Foundation
import CoreGraphics

public final class TouchInjector: @unchecked Sendable {
    private var displayID: CGDirectDisplayID
    private let queue = DispatchQueue(label: "com.antigravity.touchinjector")
    private var isLeftMouseDown: Bool = false
    
    // Direct touch tracking to avoid micro-jitter canceling clicks
    private var touchStartPoint: CGPoint = .zero
    private var isTouchDragging: Bool = false
    private var isTouchActive: Bool = false
    
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
            guard self.displayID != 0 else { return }
            let bounds = CGDisplayBounds(self.displayID)
            guard bounds.width > 0 && bounds.height > 0 else { return }
            
            switch type {
            // Direct Touch: Down
            case ScreenProtocol.ClientPacketType.touchDown.rawValue:
                let clampedX = CGFloat(max(0.0, min(1.0, normX)))
                let clampedY = CGFloat(max(0.0, min(1.0, normY)))
                let targetPoint = CGPoint(x: bounds.origin.x + clampedX * bounds.width, y: bounds.origin.y + clampedY * bounds.height)
                
                self.touchStartPoint = targetPoint
                self.isTouchDragging = false
                self.isTouchActive = true
                self.isLeftMouseDown = true
                
                CGWarpMouseCursorPosition(targetPoint)
                if let downEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: targetPoint, mouseButton: .left) {
                    downEvent.setIntegerValueField(.mouseEventClickState, value: 1)
                    downEvent.post(tap: .cghidEventTap)
                }
                
            // Direct Touch: Move
            case ScreenProtocol.ClientPacketType.touchMove.rawValue:
                guard self.isTouchActive else { return }
                let clampedX = CGFloat(max(0.0, min(1.0, normX)))
                let clampedY = CGFloat(max(0.0, min(1.0, normY)))
                let targetPoint = CGPoint(x: bounds.origin.x + clampedX * bounds.width, y: bounds.origin.y + clampedY * bounds.height)
                
                let dist = hypot(targetPoint.x - self.touchStartPoint.x, targetPoint.y - self.touchStartPoint.y)
                // Touch slop: only emit leftMouseDragged if movement is intentional (> 8 points)
                if dist > 8.0 || self.isTouchDragging {
                    self.isTouchDragging = true
                    CGWarpMouseCursorPosition(targetPoint)
                    if let dragEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: targetPoint, mouseButton: .left) {
                        dragEvent.setIntegerValueField(.mouseEventClickState, value: 1)
                        dragEvent.post(tap: .cghidEventTap)
                    }
                }
                
            // Direct Touch: Up
            case ScreenProtocol.ClientPacketType.touchUp.rawValue:
                guard self.isTouchActive else { return }
                self.isTouchActive = false
                self.isLeftMouseDown = false
                
                let clampedX = CGFloat(max(0.0, min(1.0, normX)))
                let clampedY = CGFloat(max(0.0, min(1.0, normY)))
                let targetPoint = CGPoint(x: bounds.origin.x + clampedX * bounds.width, y: bounds.origin.y + clampedY * bounds.height)
                
                if !self.isTouchDragging {
                    // Tap gesture: Warp to initial touch point and release cleanly with 20ms duration
                    CGWarpMouseCursorPosition(self.touchStartPoint)
                    usleep(20000)
                    if let upEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: self.touchStartPoint, mouseButton: .left) {
                        upEvent.setIntegerValueField(.mouseEventClickState, value: 1)
                        upEvent.post(tap: .cghidEventTap)
                    }
                } else {
                    // Drag gesture: Release at current position
                    CGWarpMouseCursorPosition(targetPoint)
                    if let upEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: targetPoint, mouseButton: .left) {
                        upEvent.setIntegerValueField(.mouseEventClickState, value: 1)
                        upEvent.post(tap: .cghidEventTap)
                    }
                    self.isTouchDragging = false
                }
                
            // Mouse / Trackpad Mode: Left Mouse Down (Press - starts selection/drag)
            case ScreenProtocol.ClientPacketType.mouseDown.rawValue:
                let curPos = CGEvent(source: nil)?.location ?? CGPoint(x: bounds.midX, y: bounds.midY)
                self.isLeftMouseDown = true
                if let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: curPos, mouseButton: .left) {
                    down.setIntegerValueField(.mouseEventClickState, value: 1)
                    down.post(tap: .cghidEventTap)
                }
                
            // Mouse / Trackpad Mode: Left Mouse Up (Release - ends selection/drag)
            case ScreenProtocol.ClientPacketType.mouseUp.rawValue:
                let curPos = CGEvent(source: nil)?.location ?? CGPoint(x: bounds.midX, y: bounds.midY)
                self.isLeftMouseDown = false
                if let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: curPos, mouseButton: .left) {
                    up.setIntegerValueField(.mouseEventClickState, value: 1)
                    up.post(tap: .cghidEventTap)
                }
                
            // Mouse / Trackpad Mode: Relative Drag (Selection drag with left mouse button held)
            case ScreenProtocol.ClientPacketType.mouseRelativeDrag.rawValue:
                let curPos = CGEvent(source: nil)?.location ?? CGPoint(x: bounds.midX, y: bounds.midY)
                if !self.isLeftMouseDown {
                    self.isLeftMouseDown = true
                    if let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: curPos, mouseButton: .left) {
                        down.setIntegerValueField(.mouseEventClickState, value: 1)
                        down.post(tap: .cghidEventTap)
                    }
                }
                let sensitivity: CGFloat = 1.6
                let newX = max(bounds.minX, min(bounds.maxX, curPos.x + CGFloat(normX) * bounds.width * sensitivity))
                let newY = max(bounds.minY, min(bounds.maxY, curPos.y + CGFloat(normY) * bounds.height * sensitivity))
                let targetPoint = CGPoint(x: newX, y: newY)
                
                CGWarpMouseCursorPosition(targetPoint)
                if let dragEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: targetPoint, mouseButton: .left) {
                    dragEvent.setIntegerValueField(.mouseEventClickState, value: 1)
                    dragEvent.post(tap: .cghidEventTap)
                }
                
            // Mouse / Trackpad Mode: Relative Move (or Drag if isLeftMouseDown is true)
            case ScreenProtocol.ClientPacketType.mouseRelativeMove.rawValue:
                let curPos = CGEvent(source: nil)?.location ?? CGPoint(x: bounds.midX, y: bounds.midY)
                let sensitivity: CGFloat = 1.6
                let newX = max(bounds.minX, min(bounds.maxX, curPos.x + CGFloat(normX) * bounds.width * sensitivity))
                let newY = max(bounds.minY, min(bounds.maxY, curPos.y + CGFloat(normY) * bounds.height * sensitivity))
                let targetPoint = CGPoint(x: newX, y: newY)
                
                CGWarpMouseCursorPosition(targetPoint)
                if self.isLeftMouseDown {
                    if let dragEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: targetPoint, mouseButton: .left) {
                        dragEvent.setIntegerValueField(.mouseEventClickState, value: 1)
                        dragEvent.post(tap: .cghidEventTap)
                    }
                } else {
                    if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: targetPoint, mouseButton: .left) {
                        moveEvent.post(tap: .cghidEventTap)
                    }
                }
                
            // Mouse / Trackpad Mode: Tap Click (at current cursor position)
            case ScreenProtocol.ClientPacketType.mouseClick.rawValue:
                let curPos = CGEvent(source: nil)?.location ?? CGPoint(x: bounds.midX, y: bounds.midY)
                self.isLeftMouseDown = false
                if let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: curPos, mouseButton: .left) {
                    down.setIntegerValueField(.mouseEventClickState, value: 1)
                    down.post(tap: .cghidEventTap)
                }
                usleep(25000) // 25ms hold duration to guarantee click registration
                if let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: curPos, mouseButton: .left) {
                    up.setIntegerValueField(.mouseEventClickState, value: 1)
                    up.post(tap: .cghidEventTap)
                }
                
            // Mouse / Trackpad Mode: Two-finger Right Click
            case ScreenProtocol.ClientPacketType.mouseRightClick.rawValue:
                let curPos = CGEvent(source: nil)?.location ?? CGPoint(x: bounds.midX, y: bounds.midY)
                if let rightDown = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: curPos, mouseButton: .right) {
                    rightDown.setIntegerValueField(.mouseEventClickState, value: 1)
                    rightDown.post(tap: .cghidEventTap)
                }
                usleep(25000)
                if let rightUp = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: curPos, mouseButton: .right) {
                    rightUp.setIntegerValueField(.mouseEventClickState, value: 1)
                    rightUp.post(tap: .cghidEventTap)
                }
                
            // Scroll (deltaY)
            case ScreenProtocol.ClientPacketType.scroll.rawValue:
                let curPos = CGEvent(source: nil)?.location ?? CGPoint(x: bounds.midX, y: bounds.midY)
                if let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(deltaY), wheel2: 0, wheel3: 0) {
                    scrollEvent.location = curPos
                    scrollEvent.post(tap: .cghidEventTap)
                }
                
            default:
                break
            }
        }
    }
}
