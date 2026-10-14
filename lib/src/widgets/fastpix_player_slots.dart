import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Each controller's hidden-slot engine, for the SDK's surfaces.
///
/// Registered rather than exposed, like the spritesheet managers: the
/// controller's own getter is for tests only.
final Expando<ValueListenable<BetterPlayerController?>>
fastPixPrerenderEngines = Expando<ValueListenable<BetterPlayerController?>>(
  'fastPixPrerenderEngines',
);

/// The keyed slots a surface draws its engine players in: the active one,
/// and while a prerender is live, a hidden one beneath it.
///
/// Each slot is keyed by its engine player, not by its position, so promoting
/// the hidden player moves its existing element — and the `UiKitView` or
/// `Texture` in it — to the active slot instead of building a new one. On iOS a
/// new view means a new `AVPlayerLayer` with no frame.
///
/// Both slots have the same shape and differ only in their flags, because an
/// element cannot move between differently shaped parents.
class FastPixPlayerSlots {
  final Map<BetterPlayerController, GlobalKey> _keys =
      <BetterPlayerController, GlobalKey>{};
  BetterPlayerController? _lastActive;

  /// The key [engine]'s slot is built under, for as long as it is shown.
  GlobalKey keyFor(BetterPlayerController engine) =>
      _keys.putIfAbsent(engine, () => GlobalKey(debugLabel: 'fastpix-player'));

  /// Assign keys for this build's [active] and [hidden] players.
  ///
  /// A new active player that was not hidden takes over the key of the one it
  /// replaced, so an ordinary source change updates the same `BetterPlayer`
  /// element exactly as it did before slots existed. Only a promotion — the
  /// hidden player becoming active — moves keys. Keys of players no longer
  /// shown are forgotten, so a released engine player is not held by one.
  void bind(BetterPlayerController active, BetterPlayerController? hidden) {
    if (!_keys.containsKey(active)) {
      final previous = _lastActive;
      final inherited = previous == null || identical(previous, hidden)
          ? null
          : _keys[previous];
      _keys[active] = inherited ?? GlobalKey(debugLabel: 'fastpix-player');
    }
    if (hidden != null) keyFor(hidden);
    _keys.removeWhere(
      (engine, _) => !identical(engine, active) && !identical(engine, hidden),
    );
    _lastActive = active;
  }

  /// [engine]'s slot. A [hidden] slot is covered by an opaque [cover] — never
  /// `Opacity`, `Visibility` or `Offstage`, which would stop the platform
  /// producing the frame it exists for — and is unreachable by touch and by
  /// accessibility.
  Widget slot(
    BetterPlayerController engine, {
    required bool hidden,
    required Color cover,
  }) {
    return KeyedSubtree(
      key: keyFor(engine),
      child: IgnorePointer(
        ignoring: hidden,
        child: ExcludeSemantics(
          excluding: hidden,
          child: Stack(
            // Passed through so the player is laid out exactly as it was
            // before it had a slot around it.
            fit: StackFit.passthrough,
            children: [
              BetterPlayer(controller: engine),
              if (hidden) Positioned.fill(child: ColoredBox(color: cover)),
            ],
          ),
        ),
      ),
    );
  }
}
