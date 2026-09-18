import AVFoundation
import CoreAudio
import Foundation

/// Plays a live interleaved Float32 stream to one Core Audio output device,
/// with its own volume control. Each device gets its own ring buffer and
/// AVAudioEngine, so device clocks can't stall each other.
final class DeviceOutput {
    let deviceID: AudioObjectID
    let name: String
    private let engine = AVAudioEngine()
    private let ring: RingBuffer
    private let sourceFormat: AVAudioFormat
    private var sourceNode: AVAudioSourceNode?
    /// Real (non-silence) frames pulled from the ring by the device's render thread.
    let framesRendered = ManagedAtomic<Int>(0)
    /// Render callbacks that found the ring empty (underruns after start).
    let underruns = ManagedAtomic<Int>(0)

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    init(deviceID: AudioObjectID, sourceFormat: AVAudioFormat, bufferSeconds: Double = 1.0) {
        self.deviceID = deviceID
        self.name = deviceID.objectName
        self.sourceFormat = sourceFormat
        self.ring = RingBuffer(
            channelCount: Int(sourceFormat.channelCount),
            capacityFrames: Int(sourceFormat.sampleRate * bufferSeconds)
        )
    }

    /// Called from the tap IO thread with interleaved samples.
    func enqueue(_ samples: UnsafePointer<Float>, frameCount: Int) {
        ring.write(samples, frameCount: frameCount)
    }

    func start() throws {
        let channelCount = Int(sourceFormat.channelCount)
        let ring = self.ring
        var scratch = [Float](repeating: 0, count: 4096 * channelCount)

        // The engine graph wants the standard (deinterleaved) format; the
        // render block deinterleaves from the ring on the fly.
        guard let nodeFormat = AVAudioFormat(
            standardFormatWithSampleRate: sourceFormat.sampleRate,
            channels: sourceFormat.channelCount
        ) else {
            throw CoreAudioError.osStatus(-1, "standard format for \(name)")
        }

        let node = AVAudioSourceNode(format: nodeFormat) { _, _, frameCount, audioBufferList -> OSStatus in
            let frames = Int(frameCount)
            let needed = frames * channelCount
            if scratch.count < needed { scratch = [Float](repeating: 0, count: needed) }
            scratch.withUnsafeMutableBufferPointer { scratchPtr in
                let delivered = ring.read(into: scratchPtr.baseAddress!, frameCount: frames)
                if delivered > 0 {
                    self.framesRendered.store(self.framesRendered.load() + delivered)
                } else {
                    self.underruns.store(self.underruns.load() + 1)
                }
                let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
                if abl.count == 1, Int(abl[0].mNumberChannels) == channelCount {
                    // Interleaved destination: straight copy.
                    abl[0].mData!.assumingMemoryBound(to: Float.self)
                        .update(from: scratchPtr.baseAddress!, count: needed)
                } else {
                    // Deinterleaved destination: split channels.
                    for (ch, buffer) in abl.enumerated() where ch < channelCount {
                        let dst = buffer.mData!.assumingMemoryBound(to: Float.self)
                        for frame in 0..<frames {
                            dst[frame] = scratchPtr[frame * channelCount + ch]
                        }
                    }
                }
            }
            return noErr
        }
        sourceNode = node

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: nodeFormat)

        // Point the engine's output at our device before starting.
        try engine.outputNode.auAudioUnit.setDeviceID(deviceID)

        try engine.start()
    }

    func stop() {
        engine.stop()
    }
}
