import Foundation
import Network

public final class NetworkServer: @unchecked Sendable {
    private let port: NWEndpoint.Port
    private let serviceType: String
    private let serviceName: String
    private var listener: NWListener?
    private var clients: [NWConnection] = []
    private let lock = NSLock()
    
    public var onClientConnected: (@Sendable () -> Void)?
    public var onTouchEvent: (@Sendable (UInt8, Float, Float, Float) -> Void)?
    
    public init(port: UInt16 = ScreenProtocol.defaultPort, serviceType: String = ScreenProtocol.bonjourServiceType, serviceName: String = "MacScreenServer") {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.serviceType = serviceType
        self.serviceName = serviceName
    }
    
    public func start(width: UInt32, height: UInt32, fps: UInt32) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        
        let newListener = try NWListener(using: params, on: port)
        newListener.service = NWListener.Service(name: serviceName, type: serviceType)
        
        newListener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                print("[NetworkServer] Listening on port \(self.port.rawValue) (Bonjour: \(self.serviceType))")
            case .failed(let error):
                print("[NetworkServer] Listener failed: \(error)")
            case .cancelled:
                print("[NetworkServer] Listener cancelled.")
            default:
                break
            }
        }
        
        newListener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection, width: width, height: height, fps: fps)
        }
        
        newListener.start(queue: .main)
        self.listener = newListener
    }
    
    public func stop() {
        lock.lock()
        for client in clients {
            client.cancel()
        }
        clients.removeAll()
        listener?.cancel()
        listener = nil
        lock.unlock()
    }
    
    private func handleNewConnection(_ connection: NWConnection, width: UInt32, height: UInt32, fps: UInt32) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .ready:
                print("[NetworkServer] Client connected: \(connection?.endpoint.debugDescription ?? "unknown")")
                self?.lock.lock()
                if let conn = connection {
                    self?.clients.append(conn)
                }
                self?.lock.unlock()
                
                // Send Handshake: "ANDR" + width (4) + height (4) + fps (4)
                var handshake = Data()
                handshake.append(contentsOf: ScreenProtocol.magicBytes)
                let wBE = width.bigEndian
                let hBE = height.bigEndian
                let fBE = fps.bigEndian
                withUnsafeBytes(of: wBE) { handshake.append(contentsOf: $0) }
                withUnsafeBytes(of: hBE) { handshake.append(contentsOf: $0) }
                withUnsafeBytes(of: fBE) { handshake.append(contentsOf: $0) }
                
                connection?.send(content: handshake, completion: .contentProcessed({ error in
                    if let error = error {
                        print("[NetworkServer] Handshake send error: \(error)")
                    } else {
                        print("[NetworkServer] Handshake sent: \(width)x\(height) @ \(fps)fps")
                    }
                }))
                
                self?.onClientConnected?()
                if let conn = connection {
                    self?.readClientPackets(conn)
                }
                
            case .failed(let error):
                print("[NetworkServer] Client connection failed: \(error)")
                self?.removeClient(connection)
            case .cancelled:
                print("[NetworkServer] Client disconnected.")
                self?.removeClient(connection)
            default:
                break
            }
        }
        
        connection.start(queue: .global(qos: .userInteractive))
    }
    
    private func readClientPackets(_ connection: NWConnection, pendingBuffer: Data = Data()) {
        // Read available touch packets with accumulator to handle TCP segmentation cleanly
        connection.receive(minimumIncompleteLength: 1, maximumLength: 2048) { [weak self, weak connection] content, _, isComplete, error in
            var accumulated = pendingBuffer
            if let data = content {
                accumulated.append(data)
            }
            
            var offset = 0
            while offset + 13 <= accumulated.count {
                let packet = accumulated.subdata(in: offset..<(offset + 13))
                let type = packet[0]
                let xBits = packet.subdata(in: 1..<5).withUnsafeBytes { $0.load(as: UInt32.self) }
                let yBits = packet.subdata(in: 5..<9).withUnsafeBytes { $0.load(as: UInt32.self) }
                let dyBits = packet.subdata(in: 9..<13).withUnsafeBytes { $0.load(as: UInt32.self) }
                
                let normX = Float(bitPattern: UInt32(bigEndian: xBits))
                let normY = Float(bitPattern: UInt32(bigEndian: yBits))
                let deltaY = Float(bitPattern: UInt32(bigEndian: dyBits))
                
                self?.onTouchEvent?(type, normX, normY, deltaY)
                offset += 13
            }
            
            let remainder: Data
            if offset < accumulated.count {
                remainder = accumulated.subdata(in: offset..<accumulated.count)
            } else {
                remainder = Data()
            }
            
            if isComplete || error != nil {
                if let conn = connection {
                    self?.removeClient(conn)
                }
            } else if let conn = connection {
                self?.readClientPackets(conn, pendingBuffer: remainder)
            }
        }
    }
    
    private func removeClient(_ connection: NWConnection?) {
        guard let connection = connection else { return }
        lock.lock()
        clients.removeAll(where: { $0 === connection })
        lock.unlock()
    }
    
    public func broadcastFrame(_ data: Data) {
        lock.lock()
        let activeClients = clients
        lock.unlock()
        
        for client in activeClients {
            client.send(content: data, completion: .contentProcessed({ _ in }))
        }
    }
    
    public var hasClients: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !clients.isEmpty
    }
}
