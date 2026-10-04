import Accelerate
import AirliftRouting
import AppKit
import AVKit
import CoreAudio
import Foundation
import ServiceManagement

let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/airlift.log")

func alog(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(stamp) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(line.data(using: .utf8)!)
        try? handle.close()
    } else {
        try? line.data(using: .utf8)!.write(to: logURL)
    }
}

/// Decides on the tap IO thread whether captured audio is forwarded to the
/// ring. Forwarding opens with the first audible buffer, so nothing is lost
/// while the main thread brings the renderer up, and is closed from the main
/// thread once the source has been silent for a while.
final class AudioGate: @unchecked Sendable {
    private let ring: RingBuffer
    private let channelCount: Int
    private let lock = NSLock()
    private var open = false
    private var lastAudible: TimeInterval = 0

    /// Called on the main thread when forwarding opens.
    var onOpen: (() -> Void)?

    /// Peaks below this (-80 dBFS) count as silence.
    private let threshold: Float = 0.0001

    init(ring: RingBuffer, channelCount: Int) {
        self.ring = ring
        self.channelCount = channelCount
    }

    var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return open
    }

    var silentSeconds: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return ProcessInfo.processInfo.systemUptime - lastAudible
    }

    func process(_ samples: UnsafePointer<Float>, frameCount: Int) {
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(frameCount * channelCount))
        lock.lock(); defer { lock.unlock() }
        if peak > threshold {
            lastAudible = ProcessInfo.processInfo.systemUptime
            if !open {
                open = true
                DispatchQueue.main.async { [weak self] in self?.onOpen?() }
            }
        }
        if open { ring.write(samples, frameCount: frameCount) }
    }

    /// Stops forwarding and drops buffered audio. The ring's reader must
    /// already be stopped.
    func close() {
        lock.lock(); defer { lock.unlock() }
        open = false
        ring.reset()
    }
}

/// Owns the tap → renderer pipeline and reconciles it against the desired
/// state on every tick. The tap (which mutes the app locally) stays up while
/// the source app runs and speakers are selected; the renderer only exists
/// while the app is actually producing sound, so speakers are released when
/// playback stops.
final class StreamController {
    let context: NSObject
    private var tap: ProcessTap?
    private var ring: RingBuffer?
    private var gate: AudioGate?
    private var format: AVAudioFormat?
    private var output: RendererOutput?
    private var tappedPID: pid_t?

    /// App the user wants streamed; nil = paused.
    private(set) var desiredApp: String?
    private(set) var lastError: String?

    /// Called on the main thread when the pipeline starts or stops by itself.
    var onChange: (() -> Void)?

    /// Silence this long ends the stream; shorter gaps (track changes, brief
    /// pauses) keep the AirPlay session up.
    private let idleTimeout: TimeInterval = 30

    init(context: NSObject) {
        self.context = context
    }

    var isTapped: Bool { tap != nil }
    var isStreaming: Bool { output != nil }

    var routedDeviceNames: [String] {
        ALContextOutputDevices(context).compactMap {
            ALDeviceProperty($0, "deviceName") as? String
        }
    }

    func setDesired(app: String?) {
        desiredApp = app
        lastError = nil
        alog(app.map { "auto-streaming \($0)" } ?? "paused by user")
        tick()
    }

    /// Reconciles actual state with desired state. Called every 2s and on
    /// app launch/quit, audio-process, route and playback events.
    func tick() {
        guard let appName = desiredApp else {
            if isTapped { teardown(reason: "paused") }
            return
        }

        // Without speakers there is nowhere to send the audio, so leave the
        // app playing locally rather than muting it.
        guard !ALContextOutputDevices(context).isEmpty else {
            if isTapped { teardown(reason: "no speakers selected") }
            return
        }

        guard let app = findApp(named: appName), !app.isTerminated else {
            if isTapped { teardown(reason: "\(appName) quit") }
            return
        }

        if let pid = tappedPID, pid != app.processIdentifier {
            teardown(reason: "\(appName) restarted (pid \(pid) → \(app.processIdentifier))")
        }

        if let output, output.renderer.status == .failed {
            let error = output.renderer.error.map(String.init(describing:)) ?? "unknown"
            stopOutput(reason: "renderer failed: \(error)")
        }

        if !isTapped {
            startTap(app: app)
        }

        guard let gate else { return }
        if gate.isOpen, output == nil {
            startOutput()
        } else if output != nil, gate.silentSeconds > idleTimeout {
            stopOutput(reason: "\(appName) went quiet")
        }
    }

    private func startTap(app: NSRunningApplication) {
        do {
            // Not registered with coreaudiod yet; the process-list listener
            // re-ticks as soon as it is.
            guard let processObject = try AudioObjectID.processObject(for: app.processIdentifier) else { return }
            let tap = ProcessTap(processObject: processObject)
            try tap.start(mute: true)
            guard let format = tap.tapFormat, format.isInterleaved,
                  format.commonFormat == .pcmFormatFloat32 else {
                tap.stop()
                lastError = "unexpected tap format"
                return
            }
            let ring = RingBuffer(
                channelCount: Int(format.channelCount),
                capacityFrames: Int(format.sampleRate * 4)
            )
            let gate = AudioGate(ring: ring, channelCount: Int(format.channelCount))
            gate.onOpen = { [weak self] in
                self?.tick()
                self?.onChange?()
            }
            tap.bufferHandler = { buffer in
                let abl = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                guard let data = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
                gate.process(data, frameCount: Int(buffer.frameLength))
            }
            self.tap = tap
            self.ring = ring
            self.gate = gate
            self.format = format
            tappedPID = app.processIdentifier
            lastError = nil
            alog("tap up: \(app.localizedName ?? "?") pid=\(app.processIdentifier) format=\(format)")
        } catch {
            lastError = "\(error)"
            alog("tap start failed: \(error)")
            teardown(reason: "start failed")
        }
    }

    private func startOutput() {
        guard let format, let ring else { return }
        do {
            let output = RendererOutput(format: format, ring: ring)
            try output.start()
            if !ALRendererSetOutputContext(output.renderer, context) {
                lastError = "renderer setOutputContext: unavailable"
            } else {
                lastError = nil
            }
            self.output = output
            alog("streaming to \(routedDeviceNames.joined(separator: " + "))")
        } catch {
            lastError = "\(error)"
            alog("renderer start failed: \(error)")
        }
    }

    private func stopOutput(reason: String) {
        guard let output else { return }
        alog("streaming stopped: \(reason)")
        output.stop()
        self.output = nil
        gate?.close()
        onChange?()
    }

    private func teardown(reason: String) {
        alog("tap down: \(reason)")
        tap?.stop()
        tap = nil
        output?.stop()
        output = nil
        gate = nil
        ring = nil
        format = nil
        tappedPID = nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var pickerWindow: NSWindow?
    private var picker: AVRoutePickerView?
    private var controller: StreamController!
    private var menuTimer: Timer?

    private let routeInfoItem = NSMenuItem(title: "Speakers: none", action: nil, keyEquivalent: "")
    private let stateInfoItem = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Pause Airlift", action: #selector(toggleStreaming), keyEquivalent: "p")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let sourceMenu = NSMenu(title: "Stream From")

    private let streamingIcon = NSImage(systemSymbolName: "airplayaudio", accessibilityDescription: "Airlift")
    private let attentionIcon = NSImage(systemSymbolName: "airplayaudio.badge.exclamationmark", accessibilityDescription: "Airlift needs attention")

    private var selectedApp: String {
        get { UserDefaults.standard.string(forKey: "sourceApp") ?? "Spotify" }
        set { UserDefaults.standard.set(newValue, forKey: "sourceApp") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Reuse the same context across launches so a picked route can survive
        // an app restart instead of being orphaned on a dead context.
        let defaults = UserDefaults.standard
        var context: NSObject?
        if let savedID = defaults.string(forKey: "contextID") {
            let rehydrated = ALContextForID(savedID)
            // outputContextForID: can hand back a video-typed handle; the
            // audio type is what makes the picker offer multi-select speakers,
            // so only reuse it when the type survived.
            let type = rehydrated.flatMap { ALDeviceProperty($0, "outputContextType") as? String } ?? ""
            if type.localizedCaseInsensitiveContains("audio") {
                context = rehydrated
            }
            alog("rehydrate context \(savedID): \(rehydrated.map(String.init(describing:)) ?? "nil") type=\(type) reused=\(context != nil)")
        }
        if context == nil {
            context = ALDefaultSharedAudioContext() ?? ALCreateAudioContext()
        }
        guard let context else {
            alog("ERROR: no AVOutputContext available")
            NSApp.terminate(nil)
            return
        }
        if let id = ALContextID(context) { defaults.set(id, forKey: "contextID") }
        alog("context \(context) id=\(ALContextID(context) ?? "nil")")
        controller = StreamController(context: context)
        controller.onChange = { [weak self] in self?.refreshMenu() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        streamingIcon?.isTemplate = true
        attentionIcon?.isTemplate = true
        statusItem.button?.image = streamingIcon
        statusItem.button?.toolTip = "Airlift"

        let menu = NSMenu()
        routeInfoItem.isEnabled = false
        stateInfoItem.isEnabled = false
        menu.addItem(routeInfoItem)
        menu.addItem(stateInfoItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Choose Speakers…", action: #selector(openPicker), keyEquivalent: "s").target = self
        toggleItem.target = self
        menu.addItem(toggleItem)
        let sourceItem = NSMenuItem(title: "Stream From", action: nil, keyEquivalent: "")
        sourceMenu.delegate = self
        sourceItem.submenu = sourceMenu
        menu.addItem(sourceItem)
        // SMAppService needs a bundle identity; the bare CLI binary has none.
        if Bundle.main.bundleIdentifier != nil {
            loginItem.target = self
            menu.addItem(loginItem)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Airlift", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        menuTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.reconcile()
        }

        // React immediately instead of waiting for the next tick: the source
        // app launching/quitting, it registering with coreaudiod, and the
        // picker changing our route.
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.reconcile()
            }
        }
        var processList = propertyAddress(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(.system, &processList, .main) { [weak self] _, _ in
            self?.reconcile()
        }
        NotificationCenter.default.addObserver(
            forName: .init("AVOutputContextOutputDevicesDidChangeNotification"), object: context, queue: .main
        ) { [weak self] _ in
            self?.reconcile()
        }

        // Streaming is the default; quitting Airlift is how you opt out.
        controller.setDesired(app: selectedApp)
        refreshMenu()

        // Routes can't be restored programmatically (selecting devices needs
        // an Apple-only entitlement), so ask for speakers up front.
        if controller.routedDeviceNames.isEmpty {
            openPicker()
        }

        // Remote control for scripting/testing: `airlift ctl start|stop [app]`.
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("dev.garms.airlift.start"), object: nil, queue: .main) { [weak self] note in
            guard let self else { return }
            let app = (note.object as? String) ?? self.selectedApp
            alog("ctl: start \(app)")
            self.selectedApp = app
            self.controller.setDesired(app: app)
            self.refreshMenu()
        }
        center.addObserver(forName: .init("dev.garms.airlift.stop"), object: nil, queue: .main) { [weak self] _ in
            alog("ctl: stop")
            self?.controller.setDesired(app: nil)
            self?.refreshMenu()
        }
    }

    // Rebuilds the "Stream From" submenu each time it opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === sourceMenu else { return }
        menu.removeAllItems()
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap(\.localizedName)
        for name in Array(Set(apps)).sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            let item = NSMenuItem(title: name, action: #selector(selectSource(_:)), keyEquivalent: "")
            item.target = self
            item.state = name == selectedApp ? .on : .off
            menu.addItem(item)
        }
    }

    @objc private func selectSource(_ sender: NSMenuItem) {
        selectedApp = sender.title
        alog("source app set to \(sender.title)")
        if controller.desiredApp != nil {
            controller.setDesired(app: sender.title)
        }
        refreshMenu()
    }

    private func reconcile() {
        controller.tick()
        refreshMenu()
    }

    private func refreshMenu() {
        let names = controller.routedDeviceNames
        let app = controller.desiredApp ?? selectedApp
        routeInfoItem.title = names.isEmpty ? "Speakers: none" : "Speakers: \(names.joined(separator: " + "))"

        var needsAttention = false
        if controller.desiredApp == nil {
            stateInfoItem.title = "Paused"
        } else if names.isEmpty {
            stateInfoItem.title = "Choose speakers to start streaming"
            needsAttention = true
        } else if let err = controller.lastError {
            stateInfoItem.title = "⚠︎ \(err)"
            needsAttention = true
        } else if controller.isStreaming {
            stateInfoItem.title = "Streaming \(app)"
        } else if controller.isTapped {
            stateInfoItem.title = "Ready — streams when \(app) plays"
        } else {
            stateInfoItem.title = "Waiting for \(app)"
        }
        toggleItem.title = controller.desiredApp == nil ? "Resume Airlift" : "Pause Airlift"
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off

        // Full-strength icon while streaming, dimmed while idle.
        statusItem.button?.image = needsAttention ? (attentionIcon ?? streamingIcon) : streamingIcon
        statusItem.button?.appearsDisabled = !controller.isStreaming && !needsAttention
    }

    @objc private func openPicker() {
        if pickerWindow == nil {
            let picker = AVRoutePickerView(frame: NSRect(x: 0, y: 0, width: 60, height: 60))
            picker.isRoutePickerButtonBordered = true
            if let contextID = ALContextID(controller.context) {
                let attached = ALPickerSetOutputContextID(picker, contextID)
                alog("picker attached to context: \(attached)")
            }
            self.picker = picker

            let label = NSTextField(labelWithString: "Pick your HomePods.\nAirPlay 2 speakers can be multi-selected.")
            label.alignment = .center
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor

            let stack = NSStackView(views: [picker, label])
            stack.orientation = .vertical
            stack.spacing = 8
            stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 260, height: 140),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Airlift Speakers"
            window.contentView = stack
            window.isReleasedWhenClosed = false
            window.center()
            pickerWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        pickerWindow?.makeKeyAndOrderFront(nil)
        // Go straight to the speaker list instead of making the user click
        // the AirPlay button first.
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            _ = self?.picker?.accessibilityPerformPress()
        }
    }

    @objc private func toggleStreaming() {
        controller.setDesired(app: controller.desiredApp == nil ? selectedApp : nil)
        refreshMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            alog("launch at login: \(SMAppService.mainApp.status == .enabled)")
        } catch {
            alog("launch at login failed: \(error)")
        }
        refreshMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.setDesired(app: nil)
    }
}

func runGUI() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
    exit(0)
}
