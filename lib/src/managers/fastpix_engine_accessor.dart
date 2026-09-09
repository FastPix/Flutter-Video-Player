import 'package:better_player_plus/better_player_plus.dart';

/// How a capability manager reads the live engine controller.
///
/// The managers never hold the `BetterPlayerController` directly, because the
/// player controller swaps it (a cold build, or adopting a preloaded player)
/// after the managers are constructed. Reading it through this accessor on each
/// call means a manager always talks to the player that is actually live, and
/// returns gracefully — empty lists, no-op switches — when there is none yet.
typedef FastPixEngineAccessor = BetterPlayerController? Function();
