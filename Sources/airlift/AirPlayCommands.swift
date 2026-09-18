import AirliftRouting
import AVFoundation
import Foundation

func describeOutputDevice(_ device: NSObject) -> String {
    let name = ALDeviceProperty(device, "deviceName") as? String ?? "?"
    var parts = ["\"\(name)\""]
    if let model = ALDeviceProperty(device, "modelID") as? String { parts.append("model=\(model)") }
    if let id = ALDeviceProperty(device, "ID") as? String { parts.append("id=\(id)") }
    if let buffered = ALDeviceProperty(device, "supportsBufferedAirPlay") as? Bool {
        parts.append("bufferedAirPlay=\(buffered)")
    }
    if let groupable = ALDeviceProperty(device, "canBeGrouped") as? Bool {
        parts.append("canBeGrouped=\(groupable)")
    }
    return parts.joined(separator: " ")
}

/// Runs discovery until `queries` are all matched (or `seconds` elapse when
/// queries is empty: then it just lists everything it saw).
func discoverOutputDevices(queries: [String], seconds: Int) -> [NSObject] {
    guard let session = ALCreateDiscoverySession(1, 2) else {
        fputs("error: AVOutputDeviceDiscoverySession unavailable\n", stderr)
        exit(1)
    }
    let deadline = Date().addingTimeInterval(TimeInterval(seconds))
    var lastCount = -1
    while Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let devices = ALAvailableOutputDevices(session)
        if devices.count != lastCount {
            lastCount = devices.count
            print("discovery: \(devices.count) device(s)")
            for device in devices { print("  \(describeOutputDevice(device))") }
        }
        if !queries.isEmpty {
            let matches = matchDevices(devices, queries: queries)
            if matches.count == queries.count { return matches }
        }
    }
    return queries.isEmpty ? ALAvailableOutputDevices(session) : matchDevices(ALAvailableOutputDevices(session), queries: queries)
}

func matchDevices(_ devices: [NSObject], queries: [String]) -> [NSObject] {
    queries.compactMap { query in
        devices.first {
            let name = ALDeviceProperty($0, "deviceName") as? String ?? ""
            return name.localizedCaseInsensitiveContains(query)
        }
    }
}

func commandAirPlayDiscover(seconds: Int) {
    _ = discoverOutputDevices(queries: [], seconds: seconds)
    print("done")
}

/// Streams through AVSampleBufferAudioRenderer attached to the shared audio
/// context, wherever that context currently routes (no device selection).
func commandContextPlay(appName: String, seconds: Int) throws {
    guard let app = findApp(named: appName),
          let processObject = try AudioObjectID.processObject(for: app.processIdentifier) else {
        fputs("error: \(appName) not running or not registered with coreaudiod\n", stderr)
        exit(1)
    }
    guard let context = ALDefaultSharedAudioContext() ?? ALCreateAudioContext() else {
        fputs("error: no AVOutputContext available\n", stderr)
        exit(1)
    }
    print("context: \(context)")
    print("context devices: \(ALContextOutputDevices(context).compactMap { ALDeviceProperty($0, "deviceName") as? String })")

    let tap = ProcessTap(processObject: processObject)
    try tap.start(mute: true)
    guard let format = tap.tapFormat else { fatalError() }
    let output = RendererOutput(format: format)
    try output.start()
    print("renderer setOutputContext: \(ALRendererSetOutputContext(output.renderer, context))")
    tap.bufferHandler = { buffer in
        let abl = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard let data = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        output.enqueue(data, frameCount: Int(buffer.frameLength))
    }
    print("streaming \(seconds)s via renderer+context...")
    let end = Date().addingTimeInterval(TimeInterval(seconds))
    while Date() < end {
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        if output.renderer.status == .failed { break }
    }
    tap.stop()
    output.stop()
    print("frames enqueued: \(output.framesPlayed) rendererStatus=\(output.renderer.status.rawValue) error=\(String(describing: output.renderer.error))")
}

func commandAirPlayPlay(appName: String, seconds: Int, speakerQueries: [String]) throws {
    guard let app = findApp(named: appName) else {
        fputs("error: no running app matching \"\(appName)\"\n", stderr)
        exit(1)
    }
    guard let processObject = try AudioObjectID.processObject(for: app.processIdentifier) else {
        fputs("error: \(appName) has not registered with coreaudiod\n", stderr)
        exit(1)
    }

    print("discovering AirPlay devices...")
    let devices = discoverOutputDevices(queries: speakerQueries, seconds: 15)
    guard devices.count == speakerQueries.count else {
        fputs("error: only matched \(devices.count)/\(speakerQueries.count) speakers\n", stderr)
        exit(1)
    }
    for device in devices { print("selected: \(describeOutputDevice(device))") }

    guard let context = ALCreateAudioContext() else {
        fputs("error: AVOutputContext.iTunesAudioContext unavailable\n", stderr)
        exit(1)
    }
    print("context: \(context)")
    if let multi = ALDeviceProperty(context, "supportsMultipleOutputDevices") as? Bool {
        print("context supportsMultipleOutputDevices=\(multi)")
    }

    if !ALContextSetOutputDevices(context, devices) {
        print("setOutputDevices: unavailable, trying addOutputDevice:")
        for device in devices {
            let name = ALDeviceProperty(device, "deviceName") as? String ?? "?"
            let added = ALContextAddOutputDevice(context, device) { print("  add \"\(name)\" completed") }
            print("  addOutputDevice \"\(name)\" dispatched=\(added)")
        }
    }
    RunLoop.current.run(until: Date().addingTimeInterval(2))
    let routed = ALContextOutputDevices(context)
    print("context now has \(routed.count) output device(s): \(routed.compactMap { ALDeviceProperty($0, "deviceName") as? String })")

    // Tap Spotify and feed the renderer.
    let tap = ProcessTap(processObject: processObject)
    try tap.start(mute: true)
    guard let format = tap.tapFormat, format.isInterleaved, format.commonFormat == .pcmFormatFloat32 else {
        tap.stop()
        fputs("error: unexpected tap format\n", stderr)
        exit(1)
    }

    let output = RendererOutput(format: format)
    try output.start()
    if !ALRendererSetOutputContext(output.renderer, context) {
        print("WARNING: renderer setOutputContext: selector missing — audio will go to default device")
    }

    tap.bufferHandler = { buffer in
        let abl = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard let data = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        output.enqueue(data, frameCount: Int(buffer.frameLength))
    }

    print("streaming for \(seconds)s...")
    let end = Date().addingTimeInterval(TimeInterval(seconds))
    while Date() < end {
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        if output.renderer.status == .failed {
            print("renderer FAILED: \(String(describing: output.renderer.error))")
            break
        }
    }
    tap.stop()
    output.stop()
    print("frames enqueued to renderer: \(output.framesPlayed)")
    print("renderer status: \(output.renderer.status.rawValue) error: \(String(describing: output.renderer.error))")
    print("done")
}
