


import 'package:fastpix_flutter_core_data/fastpix_flutter_core_data.dart';

final Map<PlayerEvent?, Set<PlayerEvent>> validTransitions = {
  null: {PlayerEvent.play, PlayerEvent.error}, // first must be play
  PlayerEvent.play: {PlayerEvent.playing, PlayerEvent.ended, PlayerEvent.pause},
  PlayerEvent.playing: {
    PlayerEvent.buffering,
    PlayerEvent.pause,
    PlayerEvent.ended,
    PlayerEvent.seeking ,
    PlayerEvent.variantChanged,
    PlayerEvent.error,
  },
  PlayerEvent.buffering: {PlayerEvent.buffered, PlayerEvent.error},
  PlayerEvent.buffered: {
    PlayerEvent.pause,
    PlayerEvent.seeking,
    PlayerEvent.playing,
    PlayerEvent.ended,
    PlayerEvent.variantChanged,
  },
  PlayerEvent.pause: {
    PlayerEvent.seeking,
    PlayerEvent.play,
    PlayerEvent.ended,
    PlayerEvent.error,
    PlayerEvent.variantChanged,
  },
  PlayerEvent.seeking: {
    PlayerEvent.seeked,
    PlayerEvent.ended,
    PlayerEvent.error,
  },
  PlayerEvent.seeked: {PlayerEvent.play, PlayerEvent.ended, PlayerEvent.error},
  PlayerEvent.ended: {
    PlayerEvent.seeking,
    PlayerEvent.error,
  },
  PlayerEvent.error: {},
};
