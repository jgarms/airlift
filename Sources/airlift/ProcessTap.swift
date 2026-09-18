import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Taps the audio output of a single process (e.g. Spotify) using the
/// Core Audio process tap API (macOS 14.2+). Delivers the tapped audio
/// as AVAudioPCMBuffers on a real-time IO callback.
final class ProcessTap {
    private let processObject: AudioObjectID
    private var tapID: AudioObjectID = .init(kAudioObjectUnknown)
    private var aggregateID: AudioObjectID = .init(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private(set) var tapFormat: AVAudioFormat?

    /// Called on the IO thread with each chunk of captured audio.
    var bufferHandler: ((AVAudioPCMBuffer) -> Void)?

    init(processObject: AudioObjectID) {
        self.processObject = processObject
    }

    func start(mute: Bool = false) throws {
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [processObject])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = mute ? .mutedWhenTapped : .unmuted
        tapDescription.name = "airlift-tap"
        tapDescription.isPrivate = true

        try check(AudioHardwareCreateProcessTap(tapDescription, &tapID), "AudioHardwareCreateProcessTap")

        var streamDescription = try tapID.read(
            kAudioTapPropertyFormat,
            initialValue: AudioStreamBasicDescription()
        )
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw CoreAudioError.osStatus(-1, "AVAudioFormat(from tap ASBD)")
        }
        tapFormat = format

        // The tap only produces data when attached to an aggregate device that
        // is running, so build a private aggregate around the system output.
        let outputUID = try AudioObjectID.defaultOutputDevice().readString(kAudioDevicePropertyDeviceUID)
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "airlift-capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                ]
            ],
        ]
        try check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
            "AudioHardwareCreateAggregateDevice"
        )

        try check(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { [weak self] _, inInputData, _, _, _ in
                guard let self, let handler = self.bufferHandler, let format = self.tapFormat else { return }
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    bufferListNoCopy: inInputData,
                    deallocator: nil
                ) else { return }
                handler(buffer)
            },
            "AudioDeviceCreateIOProcIDWithBlock"
        )

        try check(AudioDeviceStart(aggregateID, ioProcID), "AudioDeviceStart")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .init(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .init(kAudioObjectUnknown)
        }
    }

    deinit {
        stop()
    }
}
