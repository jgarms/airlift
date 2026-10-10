import AppKit
import Foundation
import MediaPlayer

/// Mutable state is confined to the main queue; the worker returns only values.
final class SpotifyMetadata: @unchecked Sendable {
    private struct Track: Decodable, Equatable, Sendable {
        let id: String
        let title: String
        let artist: String
        let album: String
        let artworkURL: String
    }

    private let worker = DispatchQueue(label: "airlift.spotify-metadata")
    private var timer: Timer?
    private var generation = UUID()
    private var reading = false
    private var track: Track?
    private var artworkTask: URLSessionDataTask?
    private var onFallback: (() -> Void)?
    private var reportedFailure = false
    var onChange: (() -> Void)?

    var trackSummary: String? {
        guard let track else { return nil }
        return track.artist.isEmpty ? track.title : "\(track.title) — \(track.artist)"
    }

    func start(onFallback: @escaping () -> Void) {
        stop()
        self.onFallback = onFallback
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        generation = UUID()
        artworkTask?.cancel()
        artworkTask = nil
        let hadTrack = track != nil
        track = nil
        onFallback = nil
        reportedFailure = false
        if hadTrack { onChange?() }
    }

    private func refresh() {
        guard !reading, onFallback != nil else { return }
        reading = true
        let requestGeneration = generation
        worker.async { [weak self] in
            let result = Self.readTrack()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reading = false
                guard self.generation == requestGeneration else { return }
                self.receive(result)
            }
        }
    }

    private static func readTrack() -> Track? {
        // A subprocess keeps scripting and its Automation prompt off the UI
        // and audio threads. JSON preserves quotes and newlines in track names.
        let script = """
        const s = Application("com.spotify.client");
        if (!s.running()) { ""; } else {
            const t = s.currentTrack();
            JSON.stringify({id:t.id(), title:t.name(), artist:t.artist(),
                album:t.album(), artworkURL:t.artworkUrl()});
        }
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-l", "JavaScript", "-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Give the initial permission prompt time to be answered, but
            // don't let an unresponsive scripting process stall future reads.
            let timeout = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeout)
            defer { timeout.cancel() }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let track = try? JSONDecoder().decode(Track.self, from: data),
                  !track.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return track
        } catch { return nil }
    }

    private func receive(_ newTrack: Track?) {
        guard let newTrack else {
            let needsFallback = track != nil || !reportedFailure
            artworkTask?.cancel()
            artworkTask = nil
            track = nil
            if needsFallback { onFallback?() }
            if needsFallback { onChange?() }
            if !reportedFailure {
                alog("Spotify metadata unavailable; using static label. Check Automation permission if this persists.")
                reportedFailure = true
            }
            return
        }
        reportedFailure = false
        guard track != newTrack else { return }
        track = newTrack
        onChange?()
        artworkTask?.cancel()
        artworkTask = nil
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = [
            MPMediaItemPropertyTitle: newTrack.title,
            MPMediaItemPropertyArtist: newTrack.artist,
            MPMediaItemPropertyAlbumTitle: newTrack.album,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        center.playbackState = .playing
        alog("Spotify Now Playing track updated")

        guard let url = URL(string: newTrack.artworkURL), url.scheme == "https" else { return }
        let requestGeneration = generation
        let request = URLRequest(url: url, timeoutInterval: 10)
        artworkTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let data, let response = response as? HTTPURLResponse,
                  response.statusCode == 200 else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == requestGeneration,
                      self.track == newTrack, let artwork = Self.makeArtwork(data: data) else { return }
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                alog("Spotify Now Playing artwork updated")
            }
        }
        artworkTask?.resume()
    }

    /// MediaPlayer invokes this handler on its own queue. Construct it outside
    /// the main-queue closure so it doesn't inherit MainActor isolation, and
    /// capture image bytes rather than sharing a mutable AppKit image.
    nonisolated static func makeArtwork(data: Data) -> MPMediaItemArtwork? {
        guard let image = NSImage(data: data) else { return nil }
        let size = image.size
        let handler: @Sendable (CGSize) -> NSImage = { _ in
            NSImage(data: data) ?? NSImage(size: size)
        }
        return MPMediaItemArtwork(boundsSize: size, requestHandler: handler)
    }
}
