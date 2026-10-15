import AVFoundation

/// Reports when a prerendered engine player has a frame ready for display on
/// its mounted, hidden layer, by textureId.
///
/// The sequence, per player: wait for the item to be ready to play; cap the
/// hidden player's forward buffer at 5 s (saving it); seek exactly to the
/// start position; preroll at the controller's rate when AVFoundation allows
/// it; then observe `isReadyForDisplay` with `.initial`, so a layer that is
/// already ready is reported without waiting for a change. `frameReady` is
/// sent once.
///
/// [restore] puts the saved value back when the player is promoted or
/// released. Main thread throughout.
final class FastPixFirstFrameDetector {
    static let shared = FastPixFirstFrameDetector()

    /// Where `frameReady` and `seekFailed` go, with the textureId.
    var send: ((String, Int64) -> Void)?

    /// The hidden player's limit on how far ahead it buffers.
    private static let hiddenForwardBuffer: TimeInterval = 5

    private final class Watch {
        let textureId: Int64
        let position: CMTime
        let rate: Float
        weak var player: AVPlayer?
        weak var layer: AVPlayerLayer?
        var status: NSKeyValueObservation?
        var readiness: NSKeyValueObservation?
        var positioned = false
        var reported = false

        init(textureId: Int64, position: CMTime, rate: Float,
             player: AVPlayer, layer: AVPlayerLayer) {
            self.textureId = textureId
            self.position = position
            self.rate = rate
            self.player = player
            self.layer = layer
        }

        func invalidate() {
            status?.invalidate()
            status = nil
            readiness?.invalidate()
            readiness = nil
        }
    }

    /// What the hidden player had before it was restricted.
    private struct Saved {
        weak var player: AVPlayer?
        let forwardBuffer: TimeInterval
    }

    private var watches: [Int64: Watch] = [:]
    private var saved: [Int64: Saved] = [:]

    /// Position [textureId]'s player at [positionMs] and report its frame.
    /// False when its layer is not mounted or it has no item.
    func watch(textureId: Int64, positionMs: Int64, rate: Double) -> Bool {
        guard let layer = FastPixPipOwner.layer(forTextureId: textureId),
              let player = layer.player,
              let item = player.currentItem else { return false }
        stop(textureId: textureId)
        let watch = Watch(
            textureId: textureId,
            position: CMTime(value: positionMs, timescale: 1000),
            rate: Float(rate > 0 ? rate : 1),
            player: player,
            layer: layer)
        watches[textureId] = watch
        watch.status = item.observe(\.status, options: [.initial, .new]) {
            [weak self] item, _ in
            DispatchQueue.main.async {
                self?.itemStatusChanged(textureId: textureId, item: item)
            }
        }
        return true
    }

    /// Stop observing [textureId]. Its restrictions stay until [restore].
    func stop(textureId: Int64) {
        watches.removeValue(forKey: textureId)?.invalidate()
    }

    /// Put back what the hidden player had, and stop observing it.
    func restore(textureId: Int64) {
        stop(textureId: textureId)
        guard let values = saved.removeValue(forKey: textureId),
              let player = values.player else { return }
        player.currentItem?.preferredForwardBufferDuration = values.forwardBuffer
    }

    private func itemStatusChanged(textureId: Int64, item: AVPlayerItem) {
        guard let watch = watches[textureId], !watch.positioned,
              item.status == .readyToPlay,
              let player = watch.player else { return }
        watch.positioned = true
        watch.status?.invalidate()
        watch.status = nil
        restrict(textureId: textureId, player: player, item: item)
        player.seek(to: watch.position, toleranceBefore: .zero, toleranceAfter: .zero) {
            [weak self] finished in
            DispatchQueue.main.async {
                self?.positioned(textureId: textureId, finished: finished)
            }
        }
    }

    private func positioned(textureId: Int64, finished: Bool) {
        guard let watch = watches[textureId],
              let player = watch.player,
              let layer = watch.layer else { return }
        guard finished else {
            stop(textureId: textureId)
            send?("seekFailed", textureId)
            return
        }
        // preroll(atRate:) raises unless the player is ready and paused.
        if player.status == .readyToPlay,
           player.currentItem?.status == .readyToPlay,
           player.rate == 0 {
            player.preroll(atRate: watch.rate, completionHandler: nil)
        }
        watch.readiness = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) {
            [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async { self?.ready(textureId: textureId) }
        }
    }

    private func ready(textureId: Int64) {
        guard let watch = watches[textureId], !watch.reported else { return }
        watch.reported = true
        stop(textureId: textureId)
        send?("frameReady", textureId)
    }

    /// A short buffer while hidden.
    private func restrict(textureId: Int64, player: AVPlayer, item: AVPlayerItem) {
        if saved[textureId] == nil {
            saved[textureId] = Saved(
                player: player,
                forwardBuffer: item.preferredForwardBufferDuration)
        }
        item.preferredForwardBufferDuration = Self.hiddenForwardBuffer
    }
}
