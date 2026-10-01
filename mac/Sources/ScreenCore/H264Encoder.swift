import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

public final class H264Encoder: @unchecked Sendable {
    private var session: VTCompressionSession?
    private let width: Int32
    private let height: Int32
    private let bitrate: Int32
    private let fps: Int32
    
    public var onEncodedFrame: (@Sendable (Data) -> Void)?
    
    private var spsData: Data?
    private var ppsData: Data?
    private var forceNextKeyframe = true
    private var lastKeyframeData: Data?
    private let lock = NSLock()
    
    public var lastKeyframe: Data? {
        lock.lock()
        defer { lock.unlock() }
        return lastKeyframeData
    }
    
    public init(width: Int32, height: Int32, fps: Int32 = 60, bitrate: Int32 = 6_000_000) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        setupSession()
    }
    
    deinit {
        invalidate()
    }
    
    public func invalidate() {
        if let session = session {
            VTCompressionSessionInvalidate(session)
            self.session = nil
        }
    }
    
    public func requestKeyframe() {
        lock.lock()
        forceNextKeyframe = true
        lock.unlock()
    }
    
    private func setupSession() {
        let callback: VTCompressionOutputCallback = { outputCallbackRefCon, _, status, flags, sampleBuffer in
            guard status == noErr, let sampleBuffer = sampleBuffer, let refCon = outputCallbackRefCon else {
                return
            }
            let encoder = Unmanaged<H264Encoder>.fromOpaque(refCon).takeUnretainedValue()
            encoder.handleSampleBuffer(sampleBuffer, flags: flags)
        }
        
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: selfPointer,
            compressionSessionOut: &session
        )
        
        guard status == noErr, let session = session else {
            print("[H264Encoder] Failed to create VTCompressionSession: \(status)")
            return
        }
        
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFTypeRef)
        
        let limits: [Int] = [Int(bitrate / 8), 1]
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: limits as CFArray)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (fps * 2) as CFTypeRef)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        
        VTCompressionSessionPrepareToEncodeFrames(session)
        print("[H264Encoder] Configured session: \(width)x\(height) @ \(fps)fps, \(bitrate / 1_000_000) Mbps")
    }
    
    public func encode(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let session = session else { return }
        
        var properties: [String: Any]? = nil
        lock.lock()
        if forceNextKeyframe {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true]
            forceNextKeyframe = false
        }
        lock.unlock()
        
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: CMTime.invalid,
            frameProperties: properties as CFDictionary?,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        
        if status != noErr {
            print("[H264Encoder] Frame encode error: \(status)")
        }
    }
    
    private func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer, flags: VTEncodeInfoFlags) {
        guard flags.contains(.frameDropped) == false else { return }
        
        let isKeyframe: Bool
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first,
           let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKeyframe = !notSync
        } else {
            isKeyframe = true
        }
        
        var packetData = Data()
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]
        
        // On keyframe, extract SPS and PPS
        if isKeyframe, let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var spsSize = 0
            var spsCount = 0
            var spsPointer: UnsafePointer<UInt8>?
            let spsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc,
                parameterSetIndex: 0,
                parameterSetPointerOut: &spsPointer,
                parameterSetSizeOut: &spsSize,
                parameterSetCountOut: &spsCount,
                nalUnitHeaderLengthOut: nil
            )
            
            var ppsSize = 0
            var ppsPointer: UnsafePointer<UInt8>?
            let ppsStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDesc,
                parameterSetIndex: 1,
                parameterSetPointerOut: &ppsPointer,
                parameterSetSizeOut: &ppsSize,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            
            if spsStatus == noErr, let spsPointer = spsPointer, spsSize > 0 {
                packetData.append(contentsOf: startCode)
                packetData.append(spsPointer, count: spsSize)
            }
            if ppsStatus == noErr, let ppsPointer = ppsPointer, ppsSize > 0 {
                packetData.append(contentsOf: startCode)
                packetData.append(ppsPointer, count: ppsSize)
            }
        }
        
        // Extract NAL units from AVCC data buffer
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        
        guard status == noErr, let dataPointer = dataPointer else { return }
        
        var offset = 0
        let rawPointer = UnsafeRawPointer(dataPointer)
        
        while offset < totalLength - 4 {
            let nalLength = Int(rawPointer.advanced(by: offset).bindMemory(to: UInt32.self, capacity: 1).pointee.bigEndian)
            offset += 4
            
            if offset + nalLength <= totalLength {
                packetData.append(contentsOf: startCode)
                let nalBytes = rawPointer.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                packetData.append(nalBytes, count: nalLength)
                offset += nalLength
            } else {
                break
            }
        }
        
        if !packetData.isEmpty {
            // Frame packet format: [4 bytes Big-Endian payload length] [payload]
            var framePacket = Data()
            let lengthBigEndian = UInt32(packetData.count).bigEndian
            withUnsafeBytes(of: lengthBigEndian) { framePacket.append(contentsOf: $0) }
            framePacket.append(packetData)
            
            if isKeyframe {
                lock.lock()
                lastKeyframeData = framePacket
                lock.unlock()
            }
            
            onEncodedFrame?(framePacket)
        }
    }
}
