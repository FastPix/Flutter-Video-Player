import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/player_test_harness.dart';

/// The playlist surface on the controller: ingestion, validation, the active
/// item, navigation, replacement and disposal.
/// The third item, used wherever a position is jumped to by id.
const String thirdItem = 'item-2';

/// The first item of the replacement playlist.
const String firstReplacement = 'new-1';

void main() {
  PlayerTestHarness.install();
  final platform = PlayerTestHarness.platform;

  group('providing a playlist', () {
    test('adopts the items in order and starts at the requested index',
        () async {
      final controller = await PlayerTestHarness.withPlaylist(
        PlayerTestHarness.playlist(4),
        startIndex: 2,
      );

      expect(controller.hasPlaylist, isTrue);
      expect(controller.playlistCount, 4);
      expect(controller.currentPlaylistIndex, 2);
      expect(controller.currentPlaylistItem?.playbackId, thirdItem);
      expect(controller.dataSource?.playbackId, thirdItem);
      await controller.dispose();
    });

    test('every reported value derives from the index', () async {
      final controller =
          await PlayerTestHarness.withPlaylist(PlayerTestHarness.playlist(3));

      // There is no second stored "current item" that could disagree: moving
      // the index moves everything.
      expect(controller.currentPlaylistItem,
          same(controller.playlistItemAt(controller.currentPlaylistIndex)));
      await controller.next();
      await PlayerTestHarness.reportReady();
      expect(controller.currentPlaylistIndex, 1);
      expect(controller.currentPlaylistItem,
          same(controller.playlistItemAt(1)));
      expect(controller.playlistState.item, same(controller.playlistItemAt(1)));
      await controller.dispose();
    });

    test('item data is readable for any position, exactly as supplied',
        () async {
      final items = <FastPixPlayerDataSource>[
        FastPixPlayerDataSource.hls(playbackId: 'a', title: 'First'),
        FastPixPlayerDataSource.hls(
          playbackId: 'b',
          title: 'Second',
          description: 'The next one',
          thumbnailUrl: 'https://example.com/b.jpg',
          duration: const Duration(minutes: 3),
        ),
      ];
      final controller = await PlayerTestHarness.withPlaylist(items);

      final upcoming = controller.playlistItemAt(1);
      expect(upcoming, same(items[1]));
      expect(upcoming?.title, 'Second');
      expect(upcoming?.description, 'The next one');
      expect(upcoming?.thumbnailUrl, 'https://example.com/b.jpg');
      expect(upcoming?.duration, const Duration(minutes: 3));
      await controller.dispose();
    });

    test('a JSON playlist produces the same state as the list form', () async {
      const json = '''
        [
          {"playbackId": "item-0", "title": "item-0"},
          {"playbackId": "item-1", "title": "item-1"},
          {"playbackId": "item-2", "title": "item-2"}
        ]
      ''';
      final fromJson = FastPixPlayerController()..preloadRadius = 0;
      await fromJson.setPlaylistFromJson(json,
          configuration: PlayerTestHarness.configuration());
      await PlayerTestHarness.reportReady();

      final fromList =
          await PlayerTestHarness.withPlaylist(PlayerTestHarness.playlist(3));

      expect(fromJson.playlistCount, fromList.playlistCount);
      expect(fromJson.currentPlaylistIndex, fromList.currentPlaylistIndex);
      expect(
        fromJson.currentPlaylistItem?.url,
        fromList.currentPlaylistItem?.url,
      );
      expect(fromJson.playlistItemAt(2)?.title, thirdItem);
      await fromJson.dispose();
      await fromList.dispose();
    });

    test('an object with an items array is accepted too', () async {
      const json = '{"name": "Season 1", "items": [{"playbackId": "a"}]}';
      final controller = FastPixPlayerController()..preloadRadius = 0;
      await controller.setPlaylistFromJson(json,
          configuration: PlayerTestHarness.configuration());
      expect(controller.playlistCount, 1);
      await controller.dispose();
    });
  });

  group('validation', () {
    /// A rejected playlist must change nothing: it is reported, and the
    /// player carries on exactly as it was.
    Future<void> expectRejected(
      FastPixPlayerController controller,
      Future<void> Function() attempt,
      FastPixPlaylistErrorCode code,
    ) async {
      final before = controller.dataSource?.playbackId;
      final beforeCount = controller.playlistCount;
      final errors = <FastPixPlayerErrorEvent>[];
      void listener(FastPixPlayerEvent event) {
        if (event is FastPixPlayerErrorEvent) errors.add(event);
      }

      controller.addGlobalListener(listener);
      await expectLater(
        attempt(),
        throwsA(
          isA<FastPixPlaylistException>().having((e) => e.code, 'code', code),
        ),
      );
      controller.removeGlobalListener(listener);

      expect(errors, hasLength(1), reason: 'the failure is also an event');
      expect(errors.single.code, code.value);
      expect(controller.dataSource?.playbackId, before,
          reason: 'playback must be untouched');
      expect(controller.playlistCount, beforeCount);
    }

    test('an empty playlist is rejected', () async {
      final controller = await PlayerTestHarness.withPlaylist(
        PlayerTestHarness.playlist(2),
      );
      await expectRejected(
        controller,
        () => controller.setPlaylist(const <FastPixPlayerDataSource>[]),
        FastPixPlaylistErrorCode.emptyPlaylist,
      );
      await controller.dispose();
    });

    test('an entry with no playback ID is rejected, naming its position',
        () async {
      final controller = await PlayerTestHarness.withPlaylist(
        PlayerTestHarness.playlist(2),
      );
      await expectLater(
        controller.setPlaylist(<FastPixPlayerDataSource>[
          PlayerTestHarness.source('fine'),
          FastPixPlayerDataSource.hls(playbackId: ''),
        ]),
        throwsA(
          isA<FastPixPlaylistException>()
              .having((e) => e.code, 'code',
                  FastPixPlaylistErrorCode.missingPlaybackId)
              .having((e) => e.itemIndex, 'itemIndex', 1),
        ),
      );
      expect(controller.playlistItemAt(0)?.playbackId, 'item-0',
          reason: 'no partial playlist is adopted');
      await controller.dispose();
    });

    test('a start index outside the list is rejected, not clamped', () async {
      final controller = await PlayerTestHarness.withPlaylist(
        PlayerTestHarness.playlist(2),
      );
      await expectRejected(
        controller,
        () => controller.setPlaylist(
          PlayerTestHarness.playlist(3),
          startIndex: 5,
        ),
        FastPixPlaylistErrorCode.startIndexOutOfRange,
      );
      await expectRejected(
        controller,
        () => controller.setPlaylist(
          PlayerTestHarness.playlist(3),
          startIndex: -1,
        ),
        FastPixPlaylistErrorCode.startIndexOutOfRange,
      );
      await controller.dispose();
    });

    test('unparseable JSON is rejected', () async {
      final controller = await PlayerTestHarness.withPlaylist(
        PlayerTestHarness.playlist(2),
      );
      await expectRejected(
        controller,
        () => controller.setPlaylistFromJson('{not json at all'),
        FastPixPlaylistErrorCode.malformedJson,
      );
      await controller.dispose();
    });

    test('JSON of the wrong shape is rejected', () async {
      final controller = FastPixPlayerController()..preloadRadius = 0;
      await expectLater(
        controller.setPlaylistFromJson('{"videos": []}'),
        throwsA(isA<FastPixPlaylistException>().having(
            (e) => e.code, 'code', FastPixPlaylistErrorCode.malformedJson)),
      );
      expect(controller.hasPlaylist, isFalse);
      await controller.dispose();
    });
  });

  group('navigation', () {
    test('moves forward and backward, reporting that it moved', () async {
      final controller =
          await PlayerTestHarness.withPlaylist(PlayerTestHarness.playlist(3));

      expect(await controller.next(), isTrue);
      await PlayerTestHarness.reportReady();
      expect(controller.currentPlaylistIndex, 1);
      expect(controller.dataSource?.playbackId, 'item-1');

      expect(await controller.previous(), isTrue);
      await PlayerTestHarness.reportReady();
      expect(controller.currentPlaylistIndex, 0);
      expect(controller.dataSource?.playbackId, 'item-0');
      await controller.dispose();
    });

    test('a boundary reports no movement and leaves playback alone', () async {
      final controller = await PlayerTestHarness.withPlaylist(
        PlayerTestHarness.playlist(2),
        startIndex: 1,
      );
      final events = <String>[];
      controller.addGlobalListener((event) => events.add(event.type));
      final playerCount = platform.created.length;

      expect(await controller.next(), isFalse);
      expect(controller.currentPlaylistIndex, 1);
      expect(platform.created, hasLength(playerCount),
          reason: 'nothing was reloaded');
      expect(events, isEmpty, reason: 'a refused move emits nothing');
      await controller.dispose();
    });

    test('jumping to the active index reports no movement', () async {
      final controller = await PlayerTestHarness.withPlaylist(
        PlayerTestHarness.playlist(3),
        startIndex: 1,
      );
      final playerCount = platform.created.length;
      expect(await controller.jumpTo(1), isFalse);
      expect(platform.created, hasLength(playerCount),
          reason: 'playback must not restart');
      await controller.dispose();
    });

    test('an out-of-range jump reports no movement', () async {
      final controller =
          await PlayerTestHarness.withPlaylist(PlayerTestHarness.playlist(3));
      expect(await controller.jumpTo(9), isFalse);
      expect(await controller.jumpTo(-2), isFalse);
      expect(controller.currentPlaylistIndex, 0);
      await controller.dispose();
    });

    test('navigation with no playlist reports no movement', () async {
      final controller = FastPixPlayerController()..preloadRadius = 0;
      await PlayerTestHarness.load(controller, PlayerTestHarness.source('solo'));
      expect(await controller.next(), isFalse);
      expect(await controller.previous(), isFalse);
      expect(controller.hasPlaylist, isFalse);
      expect(controller.dataSource?.playbackId, 'solo');
      await controller.dispose();
    });

    test('jumping to an arbitrary index loads that item', () async {
      final controller =
          await PlayerTestHarness.withPlaylist(PlayerTestHarness.playlist(5));
      expect(await controller.jumpTo(3), isTrue);
      await PlayerTestHarness.reportReady();
      expect(controller.currentPlaylistIndex, 3);
      expect(controller.dataSource?.playbackId, 'item-3');
      await controller.dispose();
    });
  });

  group('replacing a playlist during playback', () {
    test('keeps playing when the playing item is still present', () async {
      final controller = await PlayerTestHarness.withPlaylist(
        PlayerTestHarness.playlist(3),
        startIndex: 1,
      );
      final playing = controller.betterPlayerController;
      final playerCount = platform.created.length;

      // The same item, at a different position in the new list.
      await controller.setPlaylist(<FastPixPlayerDataSource>[
        PlayerTestHarness.source('new-0'),
        PlayerTestHarness.source(firstReplacement),
        PlayerTestHarness.source('item-1'),
      ]);

      expect(controller.currentPlaylistIndex, 2,
          reason: 'the index re-points to its new position');
      expect(controller.betterPlayerController, same(playing),
          reason: 'playback continues uninterrupted');
      expect(platform.created, hasLength(playerCount));
      expect(
        platform.calls.where((call) => call.method == 'seekTo'),
        isEmpty,
        reason: 'continuing means not seeking',
      );
      await controller.dispose();
    });

    test('loads the new start index when the playing item is absent',
        () async {
      final controller = await PlayerTestHarness.withPlaylist(
        PlayerTestHarness.playlist(3),
      );
      await controller.setPlaylist(
        <FastPixPlayerDataSource>[
          PlayerTestHarness.source('new-0'),
          PlayerTestHarness.source(firstReplacement),
        ],
        startIndex: 1,
      );
      await PlayerTestHarness.reportReady();

      expect(controller.currentPlaylistIndex, 1);
      expect(controller.dataSource?.playbackId, firstReplacement);
      await controller.dispose();
    });
  });

  group('clearing', () {
    test('leaves the current item playing and navigation unavailable',
        () async {
      final controller = await PlayerTestHarness.withPlaylist(
        PlayerTestHarness.playlist(3),
        startIndex: 1,
      );
      final playing = controller.betterPlayerController;

      controller.clearPlaylist();

      expect(controller.hasPlaylist, isFalse);
      expect(controller.playlistCount, 0);
      expect(controller.currentPlaylistIndex, -1);
      expect(controller.betterPlayerController, same(playing),
          reason: 'the current item keeps playing');
      expect(await controller.next(), isFalse);
      expect(await controller.previous(), isFalse);
      await controller.dispose();
    });
  });

  group('playing a source outside the playlist', () {
    test('moves the active index when the source is one of the items',
        () async {
      final controller =
          await PlayerTestHarness.withPlaylist(PlayerTestHarness.playlist(4));

      await controller.loadPlaybackId(PlayerTestHarness.source(thirdItem));
      await PlayerTestHarness.reportReady();

      expect(controller.currentPlaylistIndex, 2);
      expect(await controller.next(), isTrue,
          reason: 'navigation continues from that position');
      await PlayerTestHarness.reportReady();
      expect(controller.currentPlaylistIndex, 3);
      await controller.dispose();
    });

    test('reports no active position when the source is not in the playlist',
        () async {
      final controller =
          await PlayerTestHarness.withPlaylist(PlayerTestHarness.playlist(3));

      await controller.loadPlaybackId(PlayerTestHarness.source('elsewhere'));
      await PlayerTestHarness.reportReady();

      expect(controller.dataSource?.playbackId, 'elsewhere');
      expect(controller.currentPlaylistIndex, -1);
      expect(controller.currentPlaylistItem, isNull);
      expect(controller.playlistCount, 3, reason: 'the playlist is still set');
      await controller.dispose();
    });
  });

  group('disposal', () {
    test('a controller playing a playlist disposes without error', () async {
      final controller =
          await PlayerTestHarness.withPlaylist(PlayerTestHarness.playlist(3));
      await expectLater(controller.dispose(), completes);
      expect(controller.hasPlaylist, isFalse);
      expect(platform.alive, isEmpty);
    });

    test('a completion after disposal advances nothing and emits nothing',
        () async {
      final controller = await PlayerTestHarness.withPlaylist(
        PlayerTestHarness.playlist(3),
      );
      controller.autoPlayNext = true;
      final texture = platform.created.last;

      await controller.dispose();
      final events = <String>[];
      controller.addGlobalListener((event) => events.add(event.type));

      await platform.emitCompleted(texture);
      await PlayerTestHarness.settle();

      expect(events, isEmpty);
      expect(controller.betterPlayerController, isNull);
      expect(platform.alive, isEmpty);
    });

    test('a source change after disposal cannot revive the controller',
        () async {
      // The `_disposed = false` line stays in initialize(), where
      // re-initialising is a deliberate, supported path. If a switch carried
      // it, an automatic advance or a queued jump would re-open a controller
      // the host had thrown away — building an engine player nothing will ever
      // release, while looking entirely correct.
      final controller =
          await PlayerTestHarness.withPlaylist(PlayerTestHarness.playlist(3));
      await controller.dispose();

      final events = <String>[];
      controller.addGlobalListener((event) => events.add(event.type));

      expect(await controller.next(), isFalse);
      await controller.loadPlaybackId(PlayerTestHarness.source('other'));
      await PlayerTestHarness.settle();

      expect(controller.betterPlayerController, isNull);
      expect(platform.alive, isEmpty);
      expect(events, isEmpty);
    });

    test('re-initializing after disposal still works', () async {
      final controller = FastPixPlayerController()..preloadRadius = 0;
      await PlayerTestHarness.load(controller, PlayerTestHarness.source('a'));
      await controller.dispose();

      await PlayerTestHarness.load(controller, PlayerTestHarness.source('b'));
      expect(controller.betterPlayerController, isNotNull);
      expect(controller.dataSource?.playbackId, 'b');
      await controller.dispose();
    });
  });
}
