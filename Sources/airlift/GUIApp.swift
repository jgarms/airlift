import AirliftRouting
import AppKit
import AVKit
import Foundation

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

/// Owns the tap → renderer pipeline and reconciles it against the desired
/// state on every tick: restarts after the source app quits/relaunches,
/// recovers a failed renderer, and re-attaches dropped AirPlay routes.
final class StreamController {
    let context: NSObject
    private var tap: ProcessTap?
    private var output: RendererOutput?
    private var tappedPID: pid_t?

    /// App the user wants streamed; nil = streaming off.
    private(set) var desiredApp: String?
    private(set) var lastError: String?

    /// Last non-empty route, kept for best-effort restore after a drop.
    private var lastGoodDevices: [NSObject] = []
    private var lastRouteRestore = Date.distantPast

    init(context: NSObject) {
        self.context = context
    }

    var isStreaming: Bool { tap != nil }

    var routedDeviceNames: [String] {
        ALContextOutputDevices(context).compactMap {
            ALDeviceProperty($0, "deviceName") as? String
        }
    }

    func setDesired(app: String?) {
        desiredApp = app
        lastError = nil
        alog(app.map { "streaming requested: \($0)" } ?? "streaming stopped by user")
        tick()
    }

    /// Reconciles actual state with desired state. Called every 2s.
    func tick() {
        guard let appName = desiredApp else {
            if isStreaming { teardown(reason: "stopped") }
            return
        }

        guard let app = findApp(named: appName), !app.isTerminated else {
            if isStreaming { teardown(reason: "\(appName) quit") }
            lastError = "\(appName) is not running — will connect when it launches"
            return
        }

        if let pid = tappedPID, pid != app.processIdentifier {
            teardown(reason: "\(appName) restarted (pid \(pid) → \(app.processIdentifier))")
        }

        if let output, output.renderer.status == .failed {
            let error = output.renderer.error.map(String.init(describing:)) ?? "unknown"
            teardown(reason: "renderer failed: \(error)")
        }

        if !isStreaming {
            startPipeline(app: app)
        }

        maintainRoute()
    }

    private func startPipeline(app: NSRunningApplication) {
        do {
            guard let processObject = try AudioObjectID.processObject(for: app.processIdentifier) else {
                lastError = "\(app.localizedName ?? "app") has produced no audio yet — press play"
                return
            }
            let tap = ProcessTap(processObject: processObject)
            try tap.start(mute: true)
            guard let format = tap.tapFormat, format.isInterleaved,
                  format.commonFormat == .pcmFormatFloat32 else {
                tap.stop()
                lastError = "unexpected tap format"
                return
            }
            let output = RendererOutput(format: format)
            try output.start()
            if !ALRendererSetOutputContext(output.renderer, context) {
                lastError = "renderer setOutputContext: unavailable"
            }
            tap.bufferHandler = { buffer in
                let abl = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                guard let data = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
                output.enqueue(data, frameCount: Int(buffer.frameLength))
            }
            self.tap = tap
            self.output = output
            tappedPID = app.processIdentifier
            lastError = nil
            alog("pipeline up: \(app.localizedName ?? "?") pid=\(app.processIdentifier) format=\(format)")
        } catch {
            lastError = "\(error)"
            alog("pipeline start failed: \(error)")
            teardown(reason: "start failed")
        }
    }

    /// Remembers healthy routes and tries to restore them if they vanish
    /// mid-stream (e.g. a HomePod rebooted). Unentitled setOutputDevices may
    /// be ignored by the system; if so the route stays empty and the menu
    /// tells the user to re-pick.
    private func maintainRoute() {
        let devices = ALContextOutputDevices(context)
        if !devices.isEmpty {
            lastGoodDevices = devices
            return
        }
        guard isStreaming, !lastGoodDevices.isEmpty,
              Date().timeIntervalSince(lastRouteRestore) > 10 else { return }
        lastRouteRestore = Date()
        let names = lastGoodDevices.compactMap { ALDeviceProperty($0, "deviceName") as? String }
        alog("route dropped — attempting restore of \(names.joined(separator: " + "))")
        if !ALContextSetOutputDevices(context, lastGoodDevices) {
            for device in lastGoodDevices {
                _ = ALContextAddOutputDevice(context, device, nil)
            }
        }
    }

    private func teardown(reason: String) {
        alog("pipeline down: \(reason)")
        tap?.stop()
        tap = nil
        output?.stop()
        output = nil
        tappedPID = nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var pickerWindow: NSWindow?
    private var controller: StreamController!
    private var menuTimer: Timer?

    private let routeInfoItem = NSMenuItem(title: "Route: none", action: nil, keyEquivalent: "")
    private let stateInfoItem = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Start Streaming", action: #selector(toggleStreaming), keyEquivalent: "p")
    private let sourceMenu = NSMenu(title: "Stream From")

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

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "♪⇄"
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
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Airlift", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        menuTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.controller.tick()
            self?.refreshMenu()
        }
        refreshMenu()

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

    private func refreshMenu() {
        let names = controller.routedDeviceNames
        routeInfoItem.title = names.isEmpty ? "Route: none (choose speakers)" : "Route: \(names.joined(separator: " + "))"
        if let err = controller.lastError {
            stateInfoItem.title = "⚠︎ \(err)"
        } else if controller.isStreaming {
            stateInfoItem.title = "Streaming \(controller.desiredApp ?? "")"
        } else if controller.desiredApp != nil {
            stateInfoItem.title = "Waiting for \(controller.desiredApp ?? "")…"
        } else {
            stateInfoItem.title = "Idle"
        }
        toggleItem.title = controller.desiredApp == nil ? "Start Streaming \(selectedApp)" : "Stop Streaming"
        statusItem.button?.title = controller.isStreaming ? "♪⇄̇" : "♪⇄"
    }

    @objc private func openPicker() {
        if pickerWindow == nil {
            let picker = AVRoutePickerView(frame: NSRect(x: 0, y: 0, width: 60, height: 60))
            picker.isRoutePickerButtonBordered = true
            if let contextID = ALContextID(controller.context) {
                let attached = ALPickerSetOutputContextID(picker, contextID)
                alog("picker attached to context: \(attached)")
            }

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
    }

    @objc private func toggleStreaming() {
        controller.setDesired(app: controller.desiredApp == nil ? selectedApp : nil)
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
