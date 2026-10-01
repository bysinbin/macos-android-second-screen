import Foundation

public struct ScreenProtocol {
    public static let defaultPort: UInt16 = 8888
    public static let touchBarPort: UInt16 = 8889
    public static let bonjourServiceType = "_androidscreen._tcp"
    public static let bonjourTouchBarType = "_androidtouchbar._tcp"
    public static let magicBytes: [UInt8] = [0x41, 0x4E, 0x44, 0x52] // "ANDR"
    
    // Packet types (Client -> Server)
    public enum ClientPacketType: UInt8 {
        case touchDown         = 0x01
        case touchMove         = 0x02
        case touchUp           = 0x03
        case touchCancel       = 0x04
        case scroll            = 0x05
        case ping              = 0x06
        case mouseRelativeMove = 0x07 // Trackpad relative cursor move: dx, dy
        case mouseClick        = 0x08 // Trackpad single tap click
        case mouseRightClick   = 0x09 // Trackpad two-finger tap right click
        case mouseRelativeDrag = 0x0A // Trackpad drag/select: dx, dy with left button down
        case mouseDown         = 0x0B // Trackpad left button down (press)
        case mouseUp           = 0x0C // Trackpad left button up (release)
    }
}
