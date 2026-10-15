import AVFoundation
import Flutter
import MediaPlayer
import UIKit

/// Makes the app iOS's "Now Playing" media app while a source plays.
///
/// Apple's `AVPlayerViewController` publishes what it is playing and answers
/// the remote commands on its own, but this SDK renders through the engine's
/// own layer, which does neither, and the engine cancels remote-control events
/// every time it disposes a player.
///
/// The commands are forwarded to Dart rather than acted on here, so a play from
/// the lock screen takes the same path as a tap in the app — the same events,
/// the same analytics.
final class FastPixNowPlaying {
    private static var channel: FlutterMethodChannel?
    private static var targets: [(MPRemoteCommand, Any)] = []

    /// The info last published, when, and at what effective rate, so it can be
    /// put back with the elapsed time carried forward.
    private static var published: [String: Any]?
    private static var publishedAt: TimeInterval = 0
    private static var publishedRate: Double = 0

    /// Restores what the engine wipes. Runs only while something is published.
    ///
    /// Polling because there is nothing to hook: the engine's `dispose`
    /// handler sets `nowPlayingInfo = [:]` and calls
    /// `endReceivingRemoteControlEvents()` for *any* player it disposes — a
    /// source change, or a preloaded player being evicted — whether or not
    /// that player ever published anything. It is Swift with no `@objc`, so it
    /// cannot be interposed, and the info centre posts no change. Dart only
    /// republishes when its snapshot changes, which during steady playback it
    /// does not, so a wipe used to stand for the rest of the video.
    private static var guardTimer: Timer?
    private static let guardInterval: TimeInterval = 1.0

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "fastpix_video_player/now_playing",
            binaryMessenger: registrar.messenger())
        self.channel = channel

        channel.setMethodCallHandler { call, result in
            switch call.method {
            case "update":
                update(call.arguments as? [String: Any] ?? [:])
                result(nil)
            case "clear":
                clear()
                result(nil)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    /// Publish what is playing, claiming the remote commands on first use.
    private static func update(_ args: [String: Any]) {
        claimCommands()
        // Re-asserted on every update: the engine calls
        // `endReceivingRemoteControlEvents()` whenever it disposes a player,
        // which every source change does.
        UIApplication.shared.beginReceivingRemoteControlEvents()

        var info: [String: Any] = [:]
        if let title = args["title"] as? String, !title.isEmpty {
            info[MPMediaItemPropertyTitle] = title
        }
        if let duration = (args["durationMs"] as? NSNumber)?.doubleValue, duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration / 1000
        }
        if let position = (args["positionMs"] as? NSNumber)?.doubleValue {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, position) / 1000
        }
        let playing = args["playing"] as? Bool ?? false
        let rate = (args["rate"] as? NSNumber)?.doubleValue ?? 1
        // iOS advances the elapsed time itself from this, so the info does not
        // need a tick of its own.
        info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? rate : 0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        if let live = args["isLive"] as? Bool {
            info[MPNowPlayingInfoPropertyIsLiveStream] = live
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        published = info
        publishedAt = ProcessInfo.processInfo.systemUptime
        publishedRate = playing ? rate : 0
        startGuard()
    }

    /// Stop describing a source, and give the commands back.
    private static func clear() {
        stopGuard()
        published = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        for (command, target) in targets {
            command.removeTarget(target)
        }
        targets.removeAll()
    }

    private static func startGuard() {
        guard guardTimer == nil else { return }
        let timer = Timer(timeInterval: guardInterval, repeats: true) { _ in
            restoreIfWiped()
        }
        // Common modes, so a scroll or a held slider does not pause the check.
        RunLoop.main.add(timer, forMode: .common)
        guardTimer = timer
    }

    private static func stopGuard() {
        guardTimer?.invalidate()
        guardTimer = nil
    }

    /// Put back what the engine took away, if it did.
    private static func restoreIfWiped() {
        guard var info = published else { return }

        // Cheap and idempotent, and the engine turns it off in the same breath
        // as the wipe, so it is re-asserted every tick rather than only on one.
        UIApplication.shared.beginReceivingRemoteControlEvents()

        // Every publish carries the media type, so its absence means the info
        // is no longer ours — wiped to `[:]`, or nil.
        let current = MPNowPlayingInfoCenter.default().nowPlayingInfo
        if current?[MPNowPlayingInfoPropertyMediaType] != nil { return }

        // Carried forward, or the lock screen jumps back to the last publish.
        if let elapsed = info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double {
            var now = elapsed +
                (ProcessInfo.processInfo.systemUptime - publishedAt) * publishedRate
            if let duration = info[MPMediaItemPropertyPlaybackDuration] as? Double {
                now = min(now, duration)
            }
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = now
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        diag("restored Now Playing after an engine wipe")
    }

    /// TEMP-DIAG: to stderr as well as the system log, because `flutter run`
    /// shows only the former on iOS.
    private static func diag(_ message: String) {
        let line = "[FastPixNowPlaying] \(message)"
        NSLog("%@", line)
        fputs(line + "\n", stderr)
    }

    private static func claimCommands() {
        guard targets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()

        func forward(_ command: MPRemoteCommand, _ name: String) {
            command.isEnabled = true
            let target = command.addTarget { _ in
                send(name)
                return .success
            }
            targets.append((command, target))
        }
        forward(center.playCommand, "play")
        forward(center.pauseCommand, "pause")
        forward(center.togglePlayPauseCommand, "toggle")

        let seek = center.changePlaybackPositionCommand
        seek.isEnabled = true
        let seekTarget = seek.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            send("seek", positionMs: Int(event.positionTime * 1000))
            return .success
        }
        targets.append((seek, seekTarget))
    }

    private static func send(_ command: String, positionMs: Int? = nil) {
        var args: [String: Any] = ["command": command]
        if let positionMs = positionMs { args["positionMs"] = positionMs }
        channel?.invokeMethod("remoteCommand", arguments: args)
    }
}
