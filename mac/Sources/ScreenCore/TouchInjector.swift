import Foundation
import CoreGraphics

public final class TouchInjector: @unchecked Sendable {
    private var displayID: CGDirectDisplayID
    private let queue = DispatchQueue(label: "com.antigravity.touchinjector")
    private var isLeftMouseDown: Bool = false
    private var currentCursorPos: CGPoint = .zero
    
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
                } else {
                    // Drag: release at current position with clickState 1
                    CGWarpMouseCursorPosition(targetPoint)
                    if let upEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: targetPoint, mouseButton: .left) {
                        upEvent.setIntegerValueField(.mouseEventClickState, value: 1)
                        upEvent.post(tap: .cghidEventTap)
                    }
                }
                
            // MARK: - Mouse Down (0x0B)
            case ScreenProtocol.ClientPacketType.mouseDown.rawValue:
                let curPos = self.currentCursorPos
                self.isLeftMouseDown = true
                CGWarpMouseCursorPosition(curPos)
                if let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: curPos, mouseButton: .left) {
                    down.setIntegerValueField(.mouseEventClickState, value: 1)
                    down.post(tap: .cghidEventTap)
                }
                
            // MARK: - Mouse Up (0x0C)
            case ScreenProtocol.ClientPacketType.mouseUp.rawValue:
                let curPos = self.currentCursorPos
                self.isLeftMouseDown = false
                CGWarpMouseCursorPosition(curPos)
                if let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: curPos, mouseButton: .left) {
                    up.setIntegerValueField(.mouseEventClickState, value: 1)
                    up.post(tap: .cghidEventTap)
                }
                
            // MARK: - Relative Drag (0x0A) - used when dragging / selecting
            case ScreenProtocol.ClientPacketType.mouseRelativeDrag.rawValue:
                let curPos = self.currentCursorPos
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
                self.currentCursorPos = targetPoint
                
                CGWarpMouseCursorPosition(targetPoint)
                if let dragEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: targetPoint, mouseButton: .left) {
                    dragEvent.setIntegerValueField(.mouseEventClickState, value: 1)
                    dragEvent.post(tap: .cghidEventTap)
                }
                
            // MARK: - Relative Move (0x07) - used for normal cursor move
            case ScreenProtocol.ClientPacketType.mouseRelativeMove.rawValue:
                let curPos = self.currentCursorPos
                
                // If a previous drag was left active, release it now!
                if self.isLeftMouseDown {
                    self.isLeftMouseDown = false
                    CGWarpMouseCursorPosition(curPos)
                    if let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: curPos, mouseButton: .left) {
                        up.setIntegerValueField(.mouseEventClickState, value: 1)
                        up.post(tap: .cghidEventTap)
                    }
                }
                
                let sensitivity: CGFloat = 1.6
                let newX = max(bounds.minX, min(bounds.maxX, curPos.x + CGFloat(normX) * bounds.width * sensitivity))
                let newY = max(bounds.minY, min(bounds.maxY, curPos.y + CGFloat(normY) * bounds.height * sensitivity))
                let targetPoint = CGPoint(x: newX, y: newY)
                self.currentCursorPos = targetPoint
                
                CGWarpMouseCursorPosition(targetPoint)
                if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: targetPoint, mouseButton: .left) {
                    moveEvent.post(tap: .cghidEventTap)
                }
                
            // MARK: - Tap Click (0x08)
            case ScreenProtocol.ClientPacketType.mouseClick.rawValue:
                let curPos = self.currentCursorPos
                self.isLeftMouseDown = false
                CGWarpMouseCursorPosition(curPos)
                if let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: curPos, mouseButton: .left) {
                    down.setIntegerValueField(.mouseEventClickState, value: 1)
                    down.post(tap: .cghidEventTap)
                }
                usleep(15000)
                if let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: curPos, mouseButton: .left) {
                    up.setIntegerValueField(.mouseEventClickState, value: 1)
                    up.post(tap: .cghidEventTap)
                }
                
            // MARK: - Two-finger Right Click (0x09)
            case ScreenProtocol.ClientPacketType.mouseRightClick.rawValue:
                let curPos = self.currentCursorPos
                CGWarpMouseCursorPosition(curPos)
                if let rightDown = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: curPos, mouseButton: .right) {
                    rightDown.setIntegerValueField(.mouseEventClickState, value: 1)
                    rightDown.post(tap: .cghidEventTap)
                }
                usleep(15000)
                if let rightUp = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: curPos, mouseButton: .right) {
                    rightUp.setIntegerValueField(.mouseEventClickState, value: 1)
                    rightUp.post(tap: .cghidEventTap)
                }
                
            // MARK: - Scroll (0x05)
            case ScreenProtocol.ClientPacketType.scroll.rawValue:
                let curPos = self.currentCursorPos
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
