import AudioToolbox
import Foundation

/// Ogg Opus (RFC 7845) decoding. The Ogg pages are demuxed here and the packets go to CoreAudio's
/// Opus codec through AudioConverter; CoreAudio's own Ogg file reader isn't on every supported macOS.
enum OpusDecoder {
    struct Header {
        var channels: Int
        var preSkip: Int
        var outputGainQ8: Int16
        var mappingFamily: UInt8
    }

    /// True when the data starts with an Ogg page carrying an `OpusHead` packet (also catches Opus saved as `.ogg`).
    static func isOggOpus(_ data: Data) -> Bool {
        guard data.count >= 36, data.prefix(4) == Data("OggS".utf8) else { return false }
        let nsegs = Int(data[data.startIndex + 26])
        let body = data.startIndex + 27 + nsegs
        guard body + 8 <= data.endIndex else { return false }
        return data[body..<(body + 8)] == Data("OpusHead".utf8)
    }

    /// Splits the first logical stream into packets and returns them with the last page's granule position.
    static func demux(_ data: Data) throws -> (packets: [Data], lastGranule: Int64) {
        var packets: [Data] = []
        var partial = Data()
        var serial: UInt32?
        var lastGranule: Int64 = -1
        var pos = data.startIndex
        let end = data.endIndex
        func u32(_ i: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[i + $1]) << (8 * $1) } }
        func i64(_ i: Int) -> Int64 { Int64(bitPattern: (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[i + $1]) << (8 * $1) }) }

        while pos + 27 <= end {
            guard data[pos] == 0x4F, data[pos + 1] == 0x67, data[pos + 2] == 0x67, data[pos + 3] == 0x53 else {
                // Resync on garbage between pages.
                pos += 1
                continue
            }
            let headerType = data[pos + 5]
            let granule = i64(pos + 6)
            let pageSerial = u32(pos + 14)
            let nsegs = Int(data[pos + 26])
            let lacing = pos + 27
            guard lacing + nsegs <= end else { break }
            let bodyLen = (0..<nsegs).reduce(0) { $0 + Int(data[lacing + $1]) }
            var body = lacing + nsegs
            let truncated = body + bodyLen > end
            defer { pos = body }

            if serial == nil { serial = pageSerial }
            guard pageSerial == serial else { body += bodyLen; continue }   // skip other multiplexed streams
            if headerType & 0x01 == 0 { partial.removeAll(keepingCapacity: true) }  // not a continuation: drop stale data

            for s in 0..<nsegs {
                let len = Int(data[lacing + s])
                if body + len > end { break }   // cut-off download: keep the whole packets before the cut
                partial.append(data[body..<(body + len)])
                body += len
                if len < 255 {
                    packets.append(partial)
                    partial = Data()
                }
            }
            if truncated {
                lastGranule = -1   // the page's granule covers packets we don't have
                break
            }
            if granule != -1 { lastGranule = granule }
            if headerType & 0x04 != 0 { break }   // end of stream
        }
        return (packets, lastGranule)
    }

    static func parseHeader(_ p: Data) throws -> Header {
        let b = [UInt8](p)
        guard b.count >= 19, Data(b[0..<8]) == Data("OpusHead".utf8) else {
            throw AudioDecodeError.failed("missing OpusHead")
        }
        guard b[8] >> 4 == 0 else { throw AudioDecodeError.unsupported("Opus header version \(b[8]) is not supported") }
        return Header(channels: Int(b[9]),
                      preSkip: Int(UInt16(b[10]) | UInt16(b[11]) << 8),
                      outputGainQ8: Int16(bitPattern: UInt16(b[16]) | UInt16(b[17]) << 8),
                      mappingFamily: b[18])
    }

    /// Samples per channel at 48 kHz in one Opus packet, from its TOC byte (RFC 6716 §3.1).
    static func packetFrames(_ p: Data) -> Int {
        guard let toc = p.first else { return 0 }
        let config = Int(toc >> 3)
        let frame: Int
        if config < 12 { frame = [480, 960, 1920, 2880][config & 3] }          // SILK
        else if config < 16 { frame = [480, 960][config & 1] }                  // hybrid
        else { frame = [120, 240, 480, 960][config & 3] }                       // CELT
        let count: Int
        switch toc & 3 {
        case 0: count = 1
        case 1, 2: count = 2
        default: count = p.count > 1 ? Int(p[p.startIndex + 1] & 0x3F) : 0
        }
        return frame * count
    }

    /// Input state for the AudioConverter callback; `buffer` must stay valid until the next callback.
    private final class Feed {
        let packets: [Data]
        let channels: UInt32
        var index: Int
        let buffer: UnsafeMutableRawPointer
        let description = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
        init(packets: [Data], start: Int, channels: Int) {
            self.packets = packets
            self.channels = UInt32(channels)
            index = start
            buffer = .allocate(byteCount: max(1, packets.map(\.count).max() ?? 1), alignment: 16)
        }
        deinit { buffer.deallocate(); description.deallocate() }
    }

    static func decode(url: URL) throws -> DecodedAudio {
        try decode(data: Data(contentsOf: url), name: url.lastPathComponent)
    }

    static func decode(data: Data, name: String) throws -> DecodedAudio {
        let (packets, lastGranule) = try demux(data)
        guard let first = packets.first else { throw AudioDecodeError.failed("\(name): no Ogg pages") }
        let head: Header
        do { head = try parseHeader(first) } catch {
            throw AudioDecodeError.failed("\(name): not an Opus stream (\(error.localizedDescription))")
        }
        guard head.channels >= 1, head.channels <= 2, head.mappingFamily <= 1 else {
            throw AudioDecodeError.unsupported("\(name): \(head.channels)-channel Opus (mapping \(head.mappingFamily)) is not supported")
        }
        // Packet 0 is OpusHead, packet 1 is OpusTags; audio starts after them.
        let audioStart = 2
        guard packets.count > audioStart else { return DecodedAudio(sampleRate: 48000, channels: Array(repeating: [], count: head.channels)) }

        let ch = head.channels
        var inFmt = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 0, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(ch), mBitsPerChannel: 0, mReserved: 0)
        var outFmt = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: UInt32(ch),
            mBitsPerChannel: 32, mReserved: 0)
        var conv: AudioConverterRef?
        var st = AudioConverterNew(&inFmt, &outFmt, &conv)
        guard st == noErr, let converter = conv else {
            throw AudioDecodeError.failed("\(name): CoreAudio has no Opus decoder (error \(st))")
        }
        defer { AudioConverterDispose(converter) }

        let total = packets[audioStart...].reduce(0) { $0 + packetFrames($1) }
        var out = [[Float]](repeating: [], count: ch)
        for c in 0..<ch { out[c].reserveCapacity(total) }

        let feed = Feed(packets: packets, start: audioStart, channels: ch)
        let block = 5760   // largest Opus packet (120 ms)
        let scratch = (0..<ch).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: block) }
        defer { scratch.forEach { $0.deallocate() } }
        let abl = AudioBufferList.allocate(maximumBuffers: ch)
        defer { abl.unsafeMutablePointer.deallocate() }

        let input: AudioConverterComplexInputDataProc = { _, ioPackets, ioData, outDesc, user in
            let feed = Unmanaged<Feed>.fromOpaque(user!).takeUnretainedValue()
            guard feed.index < feed.packets.count else {
                ioPackets.pointee = 0
                ioData.pointee.mBuffers.mDataByteSize = 0
                return noErr
            }
            let packet = feed.packets[feed.index]
            feed.index += 1
            let n = packet.count
            packet.copyBytes(to: feed.buffer.assumingMemoryBound(to: UInt8.self), count: n)
            ioPackets.pointee = 1
            ioData.pointee.mNumberBuffers = 1
            ioData.pointee.mBuffers.mNumberChannels = feed.channels
            ioData.pointee.mBuffers.mDataByteSize = UInt32(n)
            ioData.pointee.mBuffers.mData = feed.buffer
            feed.description.pointee = AudioStreamPacketDescription(
                mStartOffset: 0, mVariableFramesInPacket: UInt32(OpusDecoder.packetFrames(packet)), mDataByteSize: UInt32(n))
            outDesc?.pointee = feed.description
            return noErr
        }

        let user = Unmanaged.passUnretained(feed).toOpaque()
        while true {
            for c in 0..<ch {
                abl[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(block * 4), mData: scratch[c])
            }
            var frames = UInt32(block)
            st = AudioConverterFillComplexBuffer(converter, input, user, &frames, abl.unsafeMutablePointer, nil)
            if frames > 0 {
                for c in 0..<ch { out[c].append(contentsOf: UnsafeBufferPointer(start: scratch[c], count: Int(frames))) }
            }
            if st != noErr { throw AudioDecodeError.failed("\(name): Opus decode failed (error \(st))") }
            if frames == 0 { break }
        }
        withExtendedLifetime(feed) {}

        // CoreAudio's Opus decoder already drops its own lookahead (120 samples, not reported in
        // kAudioConverterPrimeInfo), so it hands back that much less than the packets hold. Take that from
        // the stream's pre-skip, then trim to the last granule position (RFC 7845 §4).
        let decoderDelay = max(0, min(total - out[0].count, head.preSkip))
        let skip = min(head.preSkip - decoderDelay, out[0].count)
        var length = out[0].count - skip
        if lastGranule >= 0 { length = max(0, min(length, Int(lastGranule) - head.preSkip)) }
        let gain = head.outputGainQ8 == 0 ? Float(1) : Float(pow(10, Double(head.outputGainQ8) / (20 * 256)))
        for c in 0..<ch {
            var s = Array(out[c][skip..<(skip + length)])
            if gain != 1 { for i in s.indices { s[i] *= gain } }
            out[c] = s
        }
        return DecodedAudio(sampleRate: 48000, channels: out)
    }
}
