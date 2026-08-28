import AVFoundation
import Foundation

/// Disk cache for HLS playlists and segments, served to AVFoundation through a
/// custom URL scheme.
///
/// ## Why a custom scheme
///
/// `AVAssetResourceLoader` is the only way to feed AVFoundation bytes you hold
/// yourself, and it is consulted **only for schemes AVFoundation does not
/// recognise**. So playback is handed `fastpixcache://…` instead of
/// `https://…`, every request for that asset arrives here, and we answer from
/// disk or from the network.
///
/// The alternative — better_player's `HLSCachingReverseProxyServer` — was tried
/// first and fails on signed FastPix URLs with `CoreMediaErrorDomain -12642`,
/// even with no DRM involved. See `ios_cache_path_test.dart`.
///
/// ## Never for protected content
///
/// An `AVURLAsset` has exactly one resource-loader delegate, and on protected
/// content FairPlay owns it. Taking it for caching is what produces `-12642` on
/// DRM streams. Protected sources therefore keep their `https://` URL and never
/// reach this class — the same guard FastPix's own iOS SDK applies.
///
/// ## Keyed by playbackId, never by the signed URL
///
/// FastPix URLs carry a rotating `?token=`. Keying on the full URL writes under
/// token A and reads under token B: every lookup misses, and nothing errors.
/// Entries are keyed `<playbackId>/<filename>`, which survives a token refresh.
/// This is the flaw that cannot be fixed on Android, where media3 keys HLS by
/// request URI and offers no override for it.
@objc public class FastPixSegmentPrecacher: NSObject {

    @objc public static let shared = FastPixSegmentPrecacher()

    /// The scheme playback is handed. Anything else is none of our business.
    @objc public static let scheme = "fastpixcache"

    private static let tag = "precaching"

    private let fileManager = FileManager.default
    private var cacheDirectory: URL!
    private var maxDiskSize = 200 * 1024 * 1024

    /// Playlist URL → its in-flight segment downloads, so a repeat request is a
    /// no-op and a stop actually stops something.
    private var activeTasks: [String: [URL: URLSessionDataTask]] = [:]
    private let lock = NSLock()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config)
    }()

    private override init() {
        super.init()
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = base.appendingPathComponent("FastPixSegmentCache")
        try? fileManager.createDirectory(at: cacheDirectory,
                                         withIntermediateDirectories: true)
    }

    @objc public func configure(maxDiskSizeMB: Int) {
        maxDiskSize = maxDiskSizeMB * 1024 * 1024
    }

    // MARK: - Precaching

    /// Fetch `url`'s playlist and cache its segments.
    ///
    /// `url` is the ordinary `https://` playback URL. Best effort throughout:
    /// every failure leaves playback to fetch from the network as it always
    /// has.
    @objc public func startPrecaching(url: String) {
        guard let playlistURL = URL(string: url),
              let key = Self.playbackKey(from: playlistURL) else { return }

        lock.lock()
        if activeTasks[key] != nil {
            lock.unlock()
            NSLog("%@ id=%@ already precaching — coalesced", Self.tag, key)
            return
        }
        activeTasks[key] = [:]
        lock.unlock()

        NSLog("%@ id=%@ fetching master playlist", Self.tag, key)
        fetchPlaylist(playlistURL, key: key, depth: 0)
    }

    /// Fetch one playlist, cache it, and follow it.
    ///
    /// HLS is two levels: the master lists variant playlists, and each variant
    /// lists the media segments. Stopping at the master caches a few KB of text
    /// and no video at all — which is what the first version of this did.
    ///
    /// `depth` bounds the walk at master → variant → segments. A playlist found
    /// below that is cached but not followed, so a malformed or circular
    /// manifest cannot turn a warm into an unbounded crawl.
    private func fetchPlaylist(_ url: URL, key: String, depth: Int) {
        let task = session.dataTask(with: url) { [weak self] data, _, error in
            guard let self else { return }
            guard error == nil, let data,
                  let text = String(data: data, encoding: .utf8) else {
                NSLog("%@ id=%@ playlist fetch failed: %@", Self.tag, key,
                      error?.localizedDescription ?? "no data")
                self.finish(key)
                return
            }

            // The playlist is worth keeping on its own: it is first on the
            // critical path and nothing else can start until it lands.
            self.write(data, key: key, name: url.lastPathComponent)

            let base = url.deletingLastPathComponent()
            var playlists: [URL] = []
            var segments: [URL] = []

            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                let resolved: URL
                if let absolute = URL(string: trimmed), absolute.scheme != nil {
                    resolved = absolute
                } else {
                    resolved = base.appendingPathComponent(trimmed)
                }
                if trimmed.contains(".m3u8") {
                    playlists.append(resolved)
                } else if trimmed.contains(".ts") || trimmed.contains(".m4s")
                            || trimmed.contains(".mp4") {
                    segments.append(resolved)
                }
            }

            if !segments.isEmpty {
                // Only the opening segments. This is a warm, not a download —
                // the goal is to remove the first fetches from the tap, not to
                // pull a whole title over someone's cellular data.
                let opening = Array(segments.prefix(Self.segmentsToCache))
                NSLog("%@ id=%@ caching %d of %d segments", Self.tag, key,
                      opening.count, segments.count)
                opening.forEach { self.download($0, key: key) }
                return
            }

            if depth < 1, let variant = playlists.first {
                // One variant, not all of them: caching every rendition
                // multiplies the cost by the ladder height for no benefit,
                // since playback opens on one of them.
                NSLog("%@ id=%@ following variant playlist", Self.tag, key)
                self.fetchPlaylist(variant, key: key, depth: depth + 1)
                return
            }

            NSLog("%@ id=%@ no segments found at depth %d", Self.tag, key, depth)
            self.finish(key)
        }

        lock.lock()
        activeTasks[key]?[url] = task
        lock.unlock()
        task.resume()
    }

    /// How many opening segments are cached per source.
    ///
    /// Four is roughly the first few seconds of media on a typical FastPix
    /// ladder — enough to cover the opening fetches without turning a warm into
    /// a download.
    private static let segmentsToCache = 4

    @objc public func stopPrecaching(url: String) {
        guard let parsed = URL(string: url),
              let key = Self.playbackKey(from: parsed) else { return }
        lock.lock()
        let tasks = activeTasks.removeValue(forKey: key)
        lock.unlock()
        tasks?.values.forEach { $0.cancel() }
    }

    @objc public func stopAll() {
        lock.lock()
        let all = activeTasks
        activeTasks.removeAll()
        lock.unlock()
        all.values.forEach { $0.values.forEach { $0.cancel() } }
    }

    /// Bytes held for `playbackId`. The honest measure — a "cached" that stored
    /// nothing is not cached.
    @objc public func cachedBytes(playbackId: String) -> Int {
        let dir = cacheDirectory.appendingPathComponent(playbackId)
        guard let files = try? fileManager.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) {
            $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    @objc public func clear() {
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory,
                                         withIntermediateDirectories: true)
    }

    // MARK: - Keys and paths

    /// The playbackId — the last path segment of the playlist URL, minus its
    /// extension. Stable across token rotation, which is the entire point.
    @objc public static func playbackKey(from url: URL) -> String? {
        // Segment URLs live under the playlist's directory, so walk up to the
        // component that names the asset.
        let name = url.deletingPathExtension().lastPathComponent
        return name.isEmpty ? nil : name
    }

    private func directory(for key: String) -> URL {
        cacheDirectory.appendingPathComponent(key)
    }

    private func path(key: String, name: String) -> URL {
        directory(for: key).appendingPathComponent(name)
    }

    // MARK: - Download and store

    private func download(_ url: URL, key: String) {
        let name = url.lastPathComponent
        if fileManager.fileExists(atPath: path(key: key, name: name).path) { return }

        lock.lock()
        if activeTasks[key]?[url] != nil {
            lock.unlock()
            return
        }
        lock.unlock()

        let task = session.dataTask(with: url) { [weak self] data, response, _ in
            guard let self else { return }
            defer {
                self.lock.lock()
                self.activeTasks[key]?.removeValue(forKey: url)
                let remaining = self.activeTasks[key]?.isEmpty ?? true
                self.lock.unlock()
                if remaining { self.finish(key) }
            }
            guard let data,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200 else { return }
            self.write(data, key: key, name: name)
        }

        lock.lock()
        activeTasks[key]?[url] = task
        lock.unlock()
        task.resume()
    }

    private func write(_ data: Data, key: String, name: String) {
        let target = path(key: key, name: name)
        try? fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
        try? data.write(to: target, options: .atomic)
        enforceLRU()
    }

    private func finish(_ key: String) {
        lock.lock()
        activeTasks.removeValue(forKey: key)
        lock.unlock()
        NSLog("%@ id=%@ CACHED %d bytes to disk", Self.tag, key,
              cachedBytes(playbackId: key))
    }

    private func enforceLRU() {
        guard let files = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: .skipsHiddenFiles) else { return }

        var infos: [(url: URL, size: Int, date: Date)] = []
        var total = 0
        for file in files {
            let sub = (try? fileManager.contentsOfDirectory(
                at: file,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? [file]
            for f in sub {
                let v = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = v?.fileSize ?? 0
                total += size
                infos.append((f, size, v?.contentModificationDate ?? .distantPast))
            }
        }
        guard total > maxDiskSize else { return }
        infos.sort { $0.date < $1.date }
        for info in infos {
            try? fileManager.removeItem(at: info.url)
            total -= info.size
            if total <= maxDiskSize { break }
        }
    }
}

// MARK: - AVAssetResourceLoaderDelegate

/// Answers every request for a `fastpixcache://` asset: from disk on a hit,
/// from the network on a miss (storing it on the way through).
extension FastPixSegmentPrecacher: AVAssetResourceLoaderDelegate {

    public func resourceLoader(
        _: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let requested = request.request.url,
              let origin = Self.originalURL(from: requested),
              let key = Self.playbackKey(from: origin) else { return false }

        let name = origin.lastPathComponent

        if let data = try? Data(contentsOf: path(key: key, name: name)) {
            NSLog("%@ HIT id=%@ %@ (%d bytes)", Self.tag, key, name, data.count)
            respond(request, data: data, url: origin)
            request.finishLoading()
            return true
        }

        NSLog("%@ MISS id=%@ %@ — fetching", Self.tag, key, name)
        session.dataTask(with: origin) { [weak self] data, _, error in
            guard let self, let data, error == nil else {
                request.finishLoading(with: error ?? URLError(.badServerResponse))
                return
            }
            self.write(data, key: key, name: name)
            self.respond(request, data: data, url: origin)
            request.finishLoading()
        }.resume()
        return true
    }

    /// Fill in content information and the requested byte range.
    ///
    /// AVFoundation rejects a response whose content type it cannot determine,
    /// so the MIME type is derived explicitly rather than left to guesswork.
    private func respond(_ request: AVAssetResourceLoadingRequest,
                         data: Data, url: URL) {
        if let info = request.contentInformationRequest {
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = true
            switch url.pathExtension.lowercased() {
            case "m3u8", "m3u": info.contentType = "application/x-mpegURL"
            case "ts":          info.contentType = "video/MP2T"
            case "m4s", "mp4":  info.contentType = "video/iso.segment"
            default:            info.contentType = "application/octet-stream"
            }
        }
        if let dataRequest = request.dataRequest {
            let offset = Int(dataRequest.requestedOffset)
            guard offset < data.count else { return }
            let end = min(offset + dataRequest.requestedLength, data.count)
            dataRequest.respond(with: data[offset..<end])
        }
    }

    /// `fastpixcache://host/path` → `https://host/path`.
    @objc public static func originalURL(from url: URL) -> URL? {
        guard url.scheme == scheme else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return components?.url
    }

    /// `https://host/path` → `fastpixcache://host/path`.
    @objc public static func cacheURL(from url: URL) -> URL? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = scheme
        return components?.url
    }
}
