import AVFoundation
import Foundation
import UIKit

/// Result of a successful adoption.
///
/// The asset is what carries the value — parsed manifest, content-key state,
/// an open connection. The delegate travels with it because
/// `AVAssetResourceLoader` holds its delegate **weakly**: if the preloader is
/// the only owner and it releases the entry at adoption, the delegate
/// deallocates and playback fails in a way that looks like a random
/// content-key error.
@objc public class FastPixPreloaded: NSObject {
    @objc public let asset: AVURLAsset
    @objc public let loaderDelegate: NSObject?

    init(asset: AVURLAsset, loaderDelegate: NSObject?) {
        self.asset = asset
        self.loaderDelegate = loaderDelegate
    }
}

/// Warms an `AVURLAsset` before the tap, so playback starts from a parsed
/// manifest and an open connection instead of a cold load.
///
/// ## The model
///
/// On iOS you cannot cache the bytes — the only interception point for HLS is
/// `AVAssetResourceLoader`, and on protected content that delegate is already
/// owned by content-key handling. So this warms the **object**: attach an item
/// to a muted player at rate 0, and AVFoundation resolves DNS, completes TLS,
/// fetches and parses the playlists and begins filling a buffer.
///
/// All of that belongs to the `AVURLAsset`, which is shareable. The warm
/// `AVPlayer` and its item exist only to drive the loading and are torn down at
/// adoption — an `AVPlayerItem` may belong to one `AVPlayer` only, so playback
/// builds a **fresh item from the warmed asset**.
///
/// ## Contract
///
/// Best effort. `warm` returns immediately, never throws, never blocks. Every
/// failure — never warmed, stale, token rotated, load failed — falls through to
/// an ordinary cold load. No path here may break or delay playback.
@objc public class FastPixPlayerItemPreloader: NSObject {

    @objc public static let shared = FastPixPlayerItemPreloader()

    private final class Entry {
        let url: URL
        let asset: AVURLAsset
        let player: AVPlayer
        let loaderDelegate: NSObject?
        let warmedAt: Date

        init(url: URL, asset: AVURLAsset, player: AVPlayer,
             loaderDelegate: NSObject?) {
            self.url = url
            self.asset = asset
            self.player = player
            self.loaderDelegate = loaderDelegate
            self.warmedAt = Date()
        }

        var age: TimeInterval { Date().timeIntervalSince(warmedAt) }
        var didFail: Bool { player.currentItem?.status == .failed }

        func release() {
            player.replaceCurrentItem(with: nil)
        }
    }

    /// Three, not two. A detail page needs two warms at once — an autoplaying
    /// trailer *and* the feature — so at two there is no headroom and one extra
    /// warm evicts the very title about to be played.
    private let maxEntries = 3

    /// A warm older than this is likelier to be near token expiry than useful.
    private let maxAge: TimeInterval = 240

    private var order: [String] = []
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    /// Warms dispatched vs warms adopted.
    ///
    /// The ratio is how much preparation is being thrown away, and it is what
    /// says whether to warm more aggressively or less. Neither number means
    /// much alone.
    private var dispatched = 0
    private var adopted = 0

    private static let tag = "preloading"

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleDrop),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleDrop),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - prime

    /// Pay AVFoundation's first-use cost somewhere it is free.
    ///
    /// The first `AVPlayer` in a process loads the playback stack and stands up
    /// the audio session. That is dead time, and it belongs on the splash
    /// screen rather than on the tap. Nothing is kept.
    @objc public func prime() {
        DispatchQueue.main.async {
            let clock = Date()
            let warmup = AVPlayer()
            warmup.volume = 0
            _ = AVAudioSession.sharedInstance()
            // Instantiating it is the entire point.
            _ = warmup.currentItem
            NSLog("%@ AVFoundation primed in %.0fms", Self.tag,
                  Date().timeIntervalSince(clock) * 1000)
        }
    }

    // MARK: - warm

    /// Begin warming `url` under `key`.
    ///
    /// `key` must be the **playbackId**, never the URL: playback URLs carry a
    /// rotating token, so a URL-keyed warm is written under one token and
    /// looked up under another — every lookup misses and nothing errors.
    ///
    /// Called from UI code on every detail-page open or list focus, so the
    /// common case must be a cheap no-op.
    @objc public func warm(key: String,
                           url: String,
                           headers: [String: String]) {
        guard !key.isEmpty,
              let assetURL = URL(string: url),
              assetURL.scheme?.hasPrefix("http") == true else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.lock.lock()
            var superseded: Entry?
            if let existing = self.entries[key] {
                if existing.url.path == assetURL.path,
                   existing.url == assetURL,
                   existing.age <= self.maxAge {
                    // Duplicate: same content, same token, still fresh.
                    self.lock.unlock()
                    return
                }
                // The URL changed, which means the app re-resolved and the
                // token rotated. The old warm would fail the token gate at
                // adoption anyway, so superseding now is both correct and
                // frees the slot immediately.
                superseded = self.removeLocked(key)
            }
            self.lock.unlock()
            superseded?.release()

            let asset = AVURLAsset(
                url: assetURL,
                options: ["AVURLAssetHTTPHeaderFieldsKey": headers])

            // Content-key handling is deliberately not attached here. The
            // delegate must be constructed *identically* to the playback path
            // or the state acquired is not the state playback looks for — and
            // the playback path builds it inside better_player, which this
            // cannot reach. Warming DRM with a divergent delegate would report
            // success and deliver nothing, so protected sources get the
            // network warm only until that construction can be shared.
            let loaderDelegate: NSObject? = nil

            let item = AVPlayerItem(asset: asset)
            // A warm, not a download.
            item.preferredForwardBufferDuration = 10

            let player = AVPlayer(playerItem: item)
            player.volume = 0
            player.isMuted = true
            // Fill the buffer rather than race to a playable state this player
            // will never use.
            player.automaticallyWaitsToMinimizeStalling = true

            self.lock.lock()
            self.entries[key] = Entry(url: assetURL, asset: asset,
                                      player: player,
                                      loaderDelegate: loaderDelegate)
            self.order.append(key)
            self.dispatched += 1
            let evicted = self.trimLocked()
            self.lock.unlock()
            // Always outside the lock.
            evicted.forEach { $0.release() }

            NSLog("%@ START key=%@", Self.tag, key)
        }
    }

    // MARK: - take

    /// Hand over the warmed asset for `url`, if it passes every gate.
    ///
    /// **A warm is good for one play.** The entry is removed whether or not it
    /// is handed back, so a rejected warm cannot be retried into the same
    /// failure twice.
    ///
    /// Returns nil for every ordinary miss. Callers must treat nil as the
    /// normal case and build an asset exactly as they do today.
    @objc public func take(url: String) -> FastPixPreloaded? {
        // Gate 1 — a key at all.
        guard let requested = URL(string: url),
              let key = Self.playbackKey(from: requested), !key.isEmpty else {
            return nil
        }

        lock.lock()
        guard let entry = entries[key] else {
            lock.unlock()
            NSLog("%@ MISS key=%@ — no warm", Self.tag, key)
            return nil
        }
        // Consumed either way.
        _ = removeLocked(key)
        let adoptedCount = adopted
        let dispatchedCount = dispatched
        lock.unlock()

        // Gate 2 — the key must still mean the same content. Insurance against
        // a collision handing back the wrong title.
        guard entry.url.path == requested.path else {
            entry.release()
            NSLog("%@ DISCARD key=%@ — path mismatch", Self.tag, key)
            return nil
        }

        // Gate 3 — the token must match, and this is the subtle one. The warmed
        // asset is bound to the URL it was built with, so its *remaining*
        // segment requests carry the warm's token. A mismatch means the app
        // re-resolved because that token was near expiry, and adopting it risks
        // a 403 partway into playback. A cold start is slower; a stream that
        // dies at minute two is worse.
        guard Self.token(of: entry.url) == Self.token(of: requested) else {
            entry.release()
            NSLog("%@ DISCARD key=%@ — token rotated", Self.tag, key)
            return nil
        }

        // Gate 4 — age.
        guard entry.age <= maxAge else {
            entry.release()
            NSLog("%@ DISCARD key=%@ — stale (%.0fs)", Self.tag, key, entry.age)
            return nil
        }

        // Gate 5 — a warm that already errored is worse than no warm.
        guard !entry.didFail else {
            entry.release()
            NSLog("%@ DISCARD key=%@ — warm item failed", Self.tag, key)
            return nil
        }

        let ready = entry.player.currentItem?.status == .readyToPlay
        let buffered = entry.player.currentItem?.loadedTimeRanges.first
            .map { CMTimeGetSeconds($0.timeRangeValue.duration) } ?? 0

        lock.lock()
        adopted += 1
        lock.unlock()

        // Detach the warming player before handing the asset on; the item is
        // never transferred, only the asset.
        entry.release()

        NSLog("%@ ADOPTED key=%@ after %.1fs (%@, %.1fs buffered) [%d/%d adopted]",
              Self.tag, key, entry.age, ready ? "ready" : "still loading",
              buffered, adoptedCount + 1, dispatchedCount)

        return FastPixPreloaded(asset: entry.asset,
                                loaderDelegate: entry.loaderDelegate)
    }

    // MARK: - lifecycle

    @objc public func stop(key: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let entry = self.removeLocked(key)
            self.lock.unlock()
            entry?.release()
        }
    }

    @objc public func stopAll() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let all = Array(self.entries.values)
            self.entries.removeAll()
            self.order.removeAll()
            self.lock.unlock()
            all.forEach { $0.release() }
        }
    }

    @objc public func isWarm(key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else { return false }
        return entry.age <= maxAge && !entry.didFail
    }

    // MARK: - helpers

    /// The playbackId: the last path segment without its extension.
    @objc public static func playbackKey(from url: URL) -> String? {
        let last = url.deletingPathExtension().lastPathComponent
        return last.isEmpty ? nil : last
    }

    /// The signed token, or nil when the URL carries none.
    private static func token(of url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "token" }?.value
    }

    /// Caller must hold `lock`.
    private func removeLocked(_ key: String) -> Entry? {
        guard let entry = entries.removeValue(forKey: key) else { return nil }
        order.removeAll { $0 == key }
        return entry
    }

    /// Evict oldest-first down to `maxEntries`, dropping stale entries on the
    /// way. Caller must hold `lock`; the returned entries are released outside.
    private func trimLocked() -> [Entry] {
        var evicted: [Entry] = []
        for key in order where (entries[key]?.age ?? 0) > maxAge {
            if let stale = removeLocked(key) { evicted.append(stale) }
        }
        while order.count > maxEntries, let oldest = order.first {
            if let entry = removeLocked(oldest) { evicted.append(entry) }
        }
        return evicted
    }

    /// Dropped on memory pressure and on background. Each warm holds
    /// decoder-adjacent buffers and neither case is worth defending.
    ///
    /// Note this is the *only* bulk drop. Adoption deliberately does not cancel
    /// the other warms: on a detail page the autoplaying trailer would adopt
    /// its own warm and wipe the one for the movie the viewer is about to play.
    @objc private func handleDrop() { stopAll() }
}
