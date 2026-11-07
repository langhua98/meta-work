import CoreMedia
import Foundation
import VideoToolbox

/// 被控端用硬件 H.264 编出来的画面，这边用 iPhone 的硬件解码（VideoToolbox）。
/// 一帧一帧按顺序送进来（同一时间只在一个地方调），每帧同步解出一张图。
/// 码流是 Annex-B（00 00 01 分开的 NAL）；被控端在每个关键帧前面都放了 SPS/PPS。
/// 还没收到关键帧、或者解错了（比如 App 切到后台回来），就等下一个关键帧重新开始（最多 1 秒）。
final class LiveH264Decoder: @unchecked Sendable {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sps = Data()
    private var pps = Data()
    private var waitKey = true

    private final class Result: @unchecked Sendable {
        var image: CGImage?
        var failed = false
    }

    deinit { reset() }

    /// 解一帧（一个访问单元的 Annex-B 数据）。解不出来（等关键帧、出错）返回 nil。
    func decode(_ annexB: Data) -> CGImage? {
        var newSps: Data?
        var newPps: Data?
        var vcl: [Data] = []
        var key = false
        for n in Self.split(annexB) {
            switch n[n.startIndex] & 0x1f {
            case 7: newSps = n
            case 8: newPps = n
            case 5: key = true; vcl.append(n)
            case 1: vcl.append(n)
            default: break   // SEI、AUD 之类的不用送给解码器
            }
        }
        if let s = newSps, let p = newPps, s != sps || p != pps || session == nil {
            reset()
            sps = s; pps = p
            guard build() else { return nil }
        }
        if waitKey && !key { return nil }
        guard let session, let format, !vcl.isEmpty, let sample = Self.sample(vcl, format) else { return nil }

        let r = Result()
        let st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
            status, _, image, _, _ in
            guard status == noErr else { r.failed = true; return }
            guard let image else { return }   // 解码器跳过了这一帧，不算出错
            var cg: CGImage?
            VTCreateCGImageFromCVPixelBuffer(image, options: nil, imageOut: &cg)
            r.image = cg
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        if st != noErr || r.failed {
            // 解码器坏了（切后台回来常见）：扔掉，等下一个关键帧（带着 SPS/PPS）重建
            reset()
            waitKey = true
            return nil
        }
        waitKey = false
        return r.image
    }

    private func build() -> Bool {
        var fmt: CMFormatDescription?
        let st: OSStatus = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                guard let sp = s.bindMemory(to: UInt8.self).baseAddress,
                      let pp = p.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                let ptrs: [UnsafePointer<UInt8>] = [sp, pp]
                let sizes: [Int] = [s.count, p.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: ptrs,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
            }
        }
        guard st == noErr, let fmt else { return false }
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
        var s: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: fmt,
                                           decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary,
                                           outputCallback: nil, decompressionSessionOut: &s) == noErr,
              let s else { return false }
        format = fmt
        session = s
        return true
    }

    private func reset() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
    }

    /// 把 NAL 换成解码器要的格式（每个前面 4 字节长度），包成一个样本。
    private static func sample(_ nals: [Data], _ format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var avcc = Data(capacity: nals.reduce(0) { $0 + $1.count + 4 })
        for n in nals {
            var len = UInt32(n.count).bigEndian
            withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
            avcc.append(n)
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: avcc.count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied: OSStatus = avcc.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = avcc.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                        sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    /// 按 00 00 01 / 00 00 00 01 切出每个 NAL（不含起始码）。
    static func split(_ d: Data) -> [Data] {
        let b = [UInt8](d)
        var starts: [Int] = []
        var i = 0
        while i + 2 < b.count {
            if b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1 { starts.append(i + 3); i += 3 } else { i += 1 }
        }
        var out: [Data] = []
        for (k, s) in starts.enumerated() {
            var e = k + 1 < starts.count ? starts[k + 1] - 3 : b.count
            while e > s && b[e - 1] == 0 { e -= 1 }   // 4 字节起始码多出来的 0（NAL 不会以 0 结尾）
            if e > s { out.append(Data(b[s..<e])) }
        }
        return out
    }
}
