import AppKit
import AVFoundation
import CoreAudio
import Foundation

func findApp(named name: String) -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first {
        $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame
            || $0.bundleIdentifier?.lowercased().contains(name.lowercased()) == true
    }
}

func commandDevices() throws {
    for id in try AudioObjectID.allDevices() {
        let transport = (try? id.read(kAudioDevicePropertyTransportType, initialValue: UInt32(0))) ?? 0
        print("id=\(id) transport=\(fourCharCode(transport)) name=\"\(id.objectName)\" uid=\"\(id.deviceUID)\"")
    }
}

func commandRecord(appName: String, seconds: Int, outputPath: String) throws {
    guard let app = findApp(named: appName) else {
        fputs("error: no running app matching \"\(appName)\"\n", stderr)
        exit(1)
    }
    guard let processObject = try AudioObjectID.processObject(for: app.processIdentifier) else {
        fputs("error: \(appName) (pid \(app.processIdentifier)) has not registered with coreaudiod\n", stderr)
        exit(1)
    }
    print("tapping \(app.localizedName ?? appName) pid=\(app.processIdentifier) audioObject=\(processObject)")

    let tap = ProcessTap(processObject: processObject)
    try tap.start()
    guard let format = tap.tapFormat else { fatalError("tap started without a format") }
    print("tap format: \(format)")

    let url = URL(fileURLWithPath: outputPath)
    let file = try AVAudioFile(
        forWriting: url,
        settings: format.settings,
        commonFormat: format.commonFormat,
        interleaved: format.isInterleaved
    )
    var framesWritten: Int64 = 0
    var peak: Float = 0

    tap.bufferHandler = { buffer in
        do {
            try file.write(from: buffer)
            framesWritten += Int64(buffer.frameLength)
            if let data = buffer.floatChannelData {
                for channel in 0..<Int(buffer.format.channelCount) {
                    for frame in 0..<Int(buffer.frameLength) {
                        peak = max(peak, abs(data[channel][frame]))
                    }
                }
            }
        } catch {
            fputs("write error: \(error)\n", stderr)
        }
    }

    print("recording \(seconds)s to \(outputPath)...")
    Thread.sleep(forTimeInterval: TimeInterval(seconds))
    tap.stop()
    print("done: \(framesWritten) frames written, peak sample \(peak)")
    if peak == 0 {
        print("WARNING: captured pure silence — is \(appName) playing? Is audio-capture permission granted?")
    }
}

func findOutputDevice(matching query: String) throws -> AudioObjectID? {
    let devices = try AudioObjectID.allDevices().filter { $0.outputChannelCount > 0 }
    if let exact = devices.first(where: { $0.deviceUID == query }) { return exact }
    return devices.first { $0.objectName.localizedCaseInsensitiveContains(query) }
}

func commandPlay(appName: String, seconds: Int, deviceQueries: [String], muteLocal: Bool) throws {
    guard let app = findApp(named: appName) else {
        fputs("error: no running app matching \"\(appName)\"\n", stderr)
        exit(1)
    }
    guard let processObject = try AudioObjectID.processObject(for: app.processIdentifier) else {
        fputs("error: \(appName) (pid \(app.processIdentifier)) has not registered with coreaudiod\n", stderr)
        exit(1)
    }

    let tap = ProcessTap(processObject: processObject)
    try tap.start(mute: muteLocal)
    guard let format = tap.tapFormat, format.commonFormat == .pcmFormatFloat32, format.isInterleaved else {
        tap.stop()
        fputs("error: unexpected tap format \(String(describing: tap.tapFormat))\n", stderr)
        exit(1)
    }
    print("tap format: \(format), local audio \(muteLocal ? "muted" : "unmuted")")

    var outputs: [DeviceOutput] = []
    for query in deviceQueries {
        guard let deviceID = try findOutputDevice(matching: query) else {
            fputs("error: no output device matching \"\(query)\"\n", stderr)
            tap.stop()
            exit(1)
        }
        let output = DeviceOutput(deviceID: deviceID, sourceFormat: format)
        try output.start()
        print("playing to \"\(output.name)\" (id \(deviceID))")
        outputs.append(output)
    }

    tap.bufferHandler = { buffer in
        let abl = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard let data = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let frames = Int(buffer.frameLength)
        for output in outputs {
            output.enqueue(data, frameCount: frames)
        }
    }

    print("streaming for \(seconds)s... (Ctrl-C to stop)")
    Thread.sleep(forTimeInterval: TimeInterval(seconds))
    tap.stop()
    for output in outputs {
        output.stop()
        print("\"\(output.name)\": \(output.framesRendered.load()) frames rendered, \(output.underruns.load()) underruns")
    }
    print("done")
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case nil, "gui":
    runGUI()
case "devices":
    try commandDevices()
case "record":
    guard arguments.count == 4, let seconds = Int(arguments[2]) else {
        fputs("usage: airlift record <appName> <seconds> <out.wav>\n", stderr)
        exit(64)
    }
    try commandRecord(appName: arguments[1], seconds: seconds, outputPath: arguments[3])
case "play":
    var args = Array(arguments.dropFirst())
    let muteLocal = !args.contains("--keep-local")
    args.removeAll { $0 == "--keep-local" }
    guard args.count >= 3, let seconds = Int(args[1]) else {
        fputs("usage: airlift play <appName> <seconds> <device> [<device>...] [--keep-local]\n", stderr)
        exit(64)
    }
    try commandPlay(appName: args[0], seconds: seconds, deviceQueries: Array(args.dropFirst(2)), muteLocal: muteLocal)
case "ctl":
    guard arguments.count >= 2, ["start", "stop"].contains(arguments[1]) else {
        fputs("usage: airlift ctl start [app] | stop\n", stderr)
        exit(64)
    }
    DistributedNotificationCenter.default().postNotificationName(
        .init("dev.garms.airlift.\(arguments[1])"),
        object: arguments.count > 2 ? arguments[2] : nil,
        userInfo: nil,
        deliverImmediately: true
    )
    print("sent \(arguments[1])")
case "context-play":
    guard arguments.count == 3, let seconds = Int(arguments[2]) else {
        fputs("usage: airlift context-play <appName> <seconds>\n", stderr)
        exit(64)
    }
    try commandContextPlay(appName: arguments[1], seconds: seconds)
case "airplay-discover":
    commandAirPlayDiscover(seconds: arguments.count > 1 ? Int(arguments[1]) ?? 10 : 10)
case "airplay":
    guard arguments.count >= 4, let seconds = Int(arguments[2]) else {
        fputs("usage: airlift airplay <appName> <seconds> <speaker> [<speaker>...]\n", stderr)
        exit(64)
    }
    try commandAirPlayPlay(
        appName: arguments[1],
        seconds: seconds,
        speakerQueries: Array(arguments.dropFirst(3))
    )
default:
    fputs(
        """
        usage:
          airlift devices                             list Core Audio devices
          airlift record <app> <seconds> <out.wav>    tap an app's audio to a file
          airlift play <app> <seconds> <device>...    tap an app and play to output device(s)
                                                      (--keep-local: don't mute the app locally)
          airlift airplay-discover [seconds]          list AirPlay output devices (private API)
          airlift airplay <app> <seconds> <spk>...    tap an app and AirPlay to speaker(s)

        """, stderr)
    exit(64)
}
