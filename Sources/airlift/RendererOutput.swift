import AVFoundation
import CoreMedia
import Foundation

/// Plays a live interleaved Float32 stream through AVSampleBufferAudioRenderer,
/// which is the pipeline that can be attached to an (private) AVOutputContext
/// for AirPlay 2 group playback.
final class RendererOutput {
    let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let ring: RingBuffer
    private let format: AVAudioFormat
    private let queue = DispatchQueue(label: "airlift.renderer")
    private var timer: DispatchSourceTimer?
    private var formatDescription: CMAudioFormatDescription?
    private var framesEnqueued: Int64 = 0
    private var started = false

    /// Frames to accumulate before starting the clock (AirPlay needs preroll).
    private let prerollFrames: Int
    private let chunkFrames = 4800

    init(format: AVAudioFormat, bufferSeconds: Double = 4.0, prerollSeconds: Double = 0.5) {
        self.format = format
        self.ring = RingBuffer(
            channelCount: Int(format.channelCount),
            capacityFrames: Int(format.sampleRate * bufferSeconds)
        )
        self.prerollFrames = Int(format.sampleRate * prerollSeconds)
    }

    func enqueue(_ samples: UnsafePointer<Float>, frameCount: Int) {
        ring.write(samples, frameCount: frameCount)
    }

    func start() throws {
        var asbd = format.streamDescription.pointee
        var description: CMAudioFormatDescription?
        try check(
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &description
            ),
            "CMAudioFormatDescriptionCreate"
        )
        formatDescription = description

        synchronizer.addRenderer(renderer)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.pump() }
        timer.resume()
        self.timer = timer
    }

    private func pump() {
        if !started {
            guard ring.framesAvailable >= prerollFrames else { return }
            synchronizer.setRate(1.0, time: .zero)
            started = true
        }
        while renderer.isReadyForMoreMediaData, ring.framesAvailable >= chunkFrames {
            guard let sampleBuffer = makeSampleBuffer(frameCount: chunkFrames) else { return }
            renderer.enqueue(sampleBuffer)
        }
    }

    private func makeSampleBuffer(frameCount: Int) -> CMSampleBuffer? {
        guard let formatDescription else { return nil }
        let channelCount = Int(format.channelCount)
        let byteCount = frameCount * channelCount * MemoryLayout<Float>.size

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        var scratch = [Float](repeating: 0, count: frameCount * channelCount)
        scratch.withUnsafeMutableBufferPointer { ptr in
            ring.read(into: ptr.baseAddress!, frameCount: frameCount)
            _ = CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }

        var sampleBuffer: CMSampleBuffer?
        let pts = CMTime(value: framesEnqueued, timescale: CMTimeScale(format.sampleRate))
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        framesEnqueued += Int64(frameCount)
        return sampleBuffer
    }

    var framesPlayed: Int64 { framesEnqueued }

    func stop() {
        timer?.cancel()
        timer = nil
        synchronizer.setRate(0, time: .zero)
        renderer.stopRequestingMediaData()
        renderer.flush()
    }
}
