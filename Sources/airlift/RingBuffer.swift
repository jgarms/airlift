import Foundation

/// Single-producer single-consumer ring buffer of interleaved Float32 frames.
/// Writer: the tap IO thread. Reader: one output device's render thread.
final class RingBuffer: @unchecked Sendable {
    private let channelCount: Int
    private let capacityFrames: Int
    private let storage: UnsafeMutablePointer<Float>
    private var writeIndex = ManagedAtomic<Int>(0)
    private var readIndex = ManagedAtomic<Int>(0)

    init(channelCount: Int, capacityFrames: Int) {
        self.channelCount = channelCount
        self.capacityFrames = capacityFrames
        storage = .allocate(capacity: channelCount * capacityFrames)
        storage.initialize(repeating: 0, count: channelCount * capacityFrames)
    }

    deinit {
        storage.deallocate()
    }

    var framesAvailable: Int {
        let w = writeIndex.load()
        let r = readIndex.load()
        return w - r
    }

    /// Writes interleaved frames. Drops the oldest data on overflow by
    /// advancing the read index (reader will just skip ahead).
    func write(_ samples: UnsafePointer<Float>, frameCount: Int) {
        let w = writeIndex.load()
        let r = readIndex.load()
        let free = capacityFrames - (w - r)
        if frameCount > free {
            readIndex.store(r + (frameCount - free))
        }
        for frame in 0..<frameCount {
            let slot = ((w + frame) % capacityFrames) * channelCount
            for ch in 0..<channelCount {
                storage[slot + ch] = samples[frame * channelCount + ch]
            }
        }
        writeIndex.store(w + frameCount)
    }

    /// Reads up to frameCount interleaved frames; zero-fills the remainder.
    /// Returns the number of real frames delivered.
    @discardableResult
    func read(into output: UnsafeMutablePointer<Float>, frameCount: Int) -> Int {
        let w = writeIndex.load()
        let r = readIndex.load()
        let available = min(frameCount, w - r)
        for frame in 0..<available {
            let slot = ((r + frame) % capacityFrames) * channelCount
            for ch in 0..<channelCount {
                output[frame * channelCount + ch] = storage[slot + ch]
            }
        }
        if available < frameCount {
            output.advanced(by: available * channelCount)
                .update(repeating: 0, count: (frameCount - available) * channelCount)
        }
        readIndex.store(r + available)
        return available
    }
}

/// Minimal atomic Int wrapper (memory_order_seq_cst via OSAtomic-free path).
final class ManagedAtomic<T: FixedWidthInteger>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()

    init(_ value: T) { self.value = value }

    func load() -> T {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func store(_ newValue: T) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }
}
