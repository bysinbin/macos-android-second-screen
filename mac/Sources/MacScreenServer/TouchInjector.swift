import Foundation
import CoreGraphics

public final class TouchInjector: @unchecked Sendable {
    private var displayID: CGDirectDisplayID
    private let queue = DispatchQueue(label: "com.antigravity.touchinjector")
    
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
            
            let targetX = bounds.origin.x + CGFloat(normX) * bounds.width
            let targetY = bounds.origin.y + CGFloat(normY) * bounds.height
            let targetPoint = CGPoint(x: targetX, y: targetY)
            
            switch type {
            case ScreenProtocol.ClientPacketType.touchDown.rawValue:
                // Move then mouse down
                if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: targetPoint, mouseButton: .left) {
                    moveEvent.post(tap: .cghidEventTap)
                }
                if let downEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: targetPoint, mouseButton: .left) {
                    downEvent.post(tap: .cghidEventTap)
                }
                
            case ScreenProtocol.ClientPacketType.touchMove.rawValue:
                if let dragEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: targetPoint, mouseButton: .left) {
                    dragEvent.post(tap: .cghidEventTap)
                }
                
            case ScreenProtocol.ClientPacketType.touchUp.rawValue:
                if let upEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: targetPoint, mouseButton: .left) {
                    upEvent.post(tap: .cghidEventTap)
                }
                
            case ScreenProtocol.ClientPacketType.touchRightClick.rawValue:
                if let rightDown = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: targetPoint, mouseButton: .right) {
                    rightDown.post(tap: .cghidEventTap)
                }
                if let rightUp = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: targetPoint, mouseButton: .right) {
                    rightUp.post(tap: .cghidEventTap)
                }
                
            case ScreenProtocol.ClientPacketType.scroll.rawValue:
                if let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(deltaY), wheel2: 0, wheel3: 0) {
                    scrollEvent.location = targetPoint
                    scrollEvent.post(tap: .cghidEventTap)
                }
                
            default:
                break
            }
        }
    }
}
