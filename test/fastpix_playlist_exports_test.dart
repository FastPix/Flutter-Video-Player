// Imports only the package entry point, deliberately: everything a host needs
// for a playlist must be reachable without importing anything under `src/`.
import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the whole playlist surface is exported from the package', () {
    final controller = FastPixPlayerController();

    // Types.
    expect(FastPixPlaylistManager, isNotNull);
    expect(FastPixSkipManager, isNotNull);
    expect(FastPixPlaylistState.empty, isA<FastPixPlaylistState>());
    expect(
      const FastPixPlaylistException(
        FastPixPlaylistErrorCode.emptyPlaylist,
        'message',
      ),
      isA<Exception>(),
    );
    expect(
      const FastPixSkipSegment(
        start: Duration.zero,
        end: Duration(seconds: 1),
        type: FastPixSkipType.intro,
      ).type,
      FastPixSkipType.intro,
    );
    expect(FastPixPlaylistRepeatMode.all, isA<FastPixPlaylistRepeatMode>());
    expect(
      FastPixPlaylistItemChangeReason.autoAdvance,
      isA<FastPixPlaylistItemChangeReason>(),
    );
    expect(
      FastPixSkipFailureReason.zeroLength.value,
      'zeroLength',
    );

    // Events.
    final now = DateTime.now();
    expect(
      FastPixPlaylistChangedEvent(timestamp: now, count: 1, currentIndex: 0),
      isA<FastPixPlayerEvent>(),
    );
    expect(
      FastPixPlaylistItemChangedEvent(
        timestamp: now,
        index: 0,
        previousIndex: -1,
        playbackId: 'a',
        reason: FastPixPlaylistItemChangeReason.initial,
      ),
      isA<FastPixPlayerEvent>(),
    );
    expect(
      FastPixPlaylistEndedEvent(timestamp: now, count: 1),
      isA<FastPixPlayerEvent>(),
    );
    expect(
      FastPixSkipAvailableEvent(
        timestamp: now,
        segment: const FastPixSkipSegment(
          start: Duration.zero,
          end: Duration(seconds: 1),
          type: FastPixSkipType.intro,
        ),
      ),
      isA<FastPixPlayerEvent>(),
    );
    expect(
      FastPixSkipHiddenEvent(timestamp: now),
      isA<FastPixPlayerEvent>(),
    );
    expect(
      FastPixSkipCompletedEvent(
        timestamp: now,
        segment: const FastPixSkipSegment(
          start: Duration.zero,
          end: Duration(seconds: 1),
          type: FastPixSkipType.credits,
        ),
      ),
      isA<FastPixPlayerEvent>(),
    );
    expect(
      FastPixSkipFailedEvent(
        timestamp: now,
        reason: FastPixSkipFailureReason.noActiveSegment,
        message: 'none',
      ),
      isA<FastPixPlayerEvent>(),
    );

    // Event type constants.
    expect(FastPixPlayerEventTypes.playlistChanged, 'playlistChanged');
    expect(FastPixPlayerEventTypes.playlistItemChanged, 'playlistItemChanged');
    expect(FastPixPlayerEventTypes.playlistEnded, 'playlistEnded');
    expect(FastPixPlayerEventTypes.skipAvailable, 'skipAvailable');
    expect(FastPixPlayerEventTypes.skipHidden, 'skipHidden');
    expect(FastPixPlayerEventTypes.skipCompleted, 'skipCompleted');
    expect(FastPixPlayerEventTypes.skipFailed, 'skipFailed');

    // The controller's playlist surface.
    expect(controller.hasPlaylist, isFalse);
    expect(controller.playlistCount, 0);
    expect(controller.currentPlaylistIndex, -1);
    expect(controller.currentPlaylistItem, isNull);
    expect(controller.playlistItemAt(0), isNull);
    expect(controller.canGoNext, isFalse);
    expect(controller.canGoPrevious, isFalse);
    expect(controller.playlistState, FastPixPlaylistState.empty);
    expect(controller.playlistStateStream, isA<Stream<FastPixPlaylistState>>());
    expect(controller.autoPlayNext, isFalse);
    expect(controller.repeatMode, FastPixPlaylistRepeatMode.off);
    expect(controller.preloadRadius, 2);
    expect(controller.activeSkipSegment, isNull);
    expect(controller.sourceGeneration.value, 0);

    // Parsing, from the entry point alone.
    expect(
      FastPixPlayerDataSource.fromJson(
        <String, dynamic>{'playbackId': 'abc'},
      ).playbackId,
      'abc',
    );
    expect(
      FastPixPlayerDataSource.hls(playbackId: 'abc').skipSegments,
      isNull,
    );
  });
}
