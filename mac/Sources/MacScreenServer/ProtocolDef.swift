import Foundation

public struct ScreenProtocol {
    public static let defaultPort: UInt16 = 8888
    public static let bonjourServiceType = "_androidscreen._tcp"
    public static let magicBytes: [UInt8] = [0x41, 0x4E, 0x44, 0x52] // "ANDR"
    
    // Packet types (Client -> Server)
    public enum ClientPacketType: UInt8 {
        case touchDown = 0x01
        case touchMove = 0x02
        case touchUp   = 0x03
        case touchRightClick = 0x04
        case scroll    = 0x05
        case ping      = 0x06
    }
}
