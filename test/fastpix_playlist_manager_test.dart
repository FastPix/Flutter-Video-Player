import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter_test/flutter_test.dart';

/// The playlist cursor and the models around it. No platform binding: the
/// whole contract — bounds, derivation, warm ordering — is pure logic, which
/// is exactly why it lives in a manager of its own.
/// The third item, the cursor position most cases start from.
const String thirdItem = 'item-2';

void main() {
  FastPixPlayerDataSource source(String id) =>
      FastPixPlayerDataSource.hls(playbackId: id, title: id);

  List<FastPixPlayerDataSource> sources(int count) => <FastPixPlayerDataSource>[
        for (var i = 0; i < count; i++) source('item-$i'),
      ];

  FastPixPlaylistManager managerOf(int count, {int startIndex = 0}) =>
      FastPixPlaylistManager()..setItems(sources(count), startIndex: startIndex);

  group('the active item', () {
    test('every reported value derives from the index', () {
      final manager = managerOf(5, startIndex: 2);
      expect(manager.currentIndex, 2);
      expect(manager.currentItem?.playbackId, thirdItem);
      expect(manager.count, 5);
      expect(manager.itemAt(4)?.playbackId, 'item-4');
      expect(manager.state.item, same(manager.currentItem));
    });

    test('an out-of-range index reads as no item rather than throwing', () {
      final manager = managerOf(3);
      expect(manager.itemAt(-1), isNull);
      expect(manager.itemAt(3), isNull);
    });

    test('movement availability at both ends', () {
      final first = managerOf(3);
      expect(first.canGoPrevious, isFalse);
      expect(first.canGoNext, isTrue);

      final last = managerOf(3, startIndex: 2);
      expect(last.canGoNext, isFalse);
      expect(last.canGoPrevious, isTrue);
    });

    test('a single-item playlist can move in neither direction', () {
      final manager = managerOf(1);
      expect(manager.canGoNext, isFalse);
      expect(manager.canGoPrevious, isFalse);
      expect(manager.nextItem(), isFalse);
      expect(manager.previousItem(), isFalse);
      expect(manager.currentIndex, 0);
    });
  });

  group('moving', () {
    test('forward and backward report that they moved', () {
      final manager = managerOf(3);
      expect(manager.nextItem(), isTrue);
      expect(manager.currentIndex, 1);
      expect(manager.previousItem(), isTrue);
      expect(manager.currentIndex, 0);
    });

    test('a boundary reports no movement and leaves the index alone', () {
      final manager = managerOf(2, startIndex: 1);
      expect(manager.nextItem(), isFalse);
      expect(manager.currentIndex, 1);
    });

    test('jumping to the active index reports no movement', () {
      final manager = managerOf(3, startIndex: 1);
      expect(manager.moveTo(1), isFalse);
      expect(manager.currentIndex, 1);
    });

    test('an out-of-range jump reports no movement', () {
      final manager = managerOf(3);
      expect(manager.moveTo(7), isFalse);
      expect(manager.moveTo(-1), isFalse);
      expect(manager.currentIndex, 0);
    });
  });

  group('clearing and re-pointing', () {
    test('clearing leaves no playlist and no position', () {
      final manager = managerOf(3, startIndex: 1)..clear();
      expect(manager.count, 0);
      expect(manager.currentIndex, -1);
      expect(manager.currentItem, isNull);
      expect(manager.state, FastPixPlaylistState.empty);
    });

    test('re-pointing to an unknown position reports no active item', () {
      final manager = managerOf(3, startIndex: 1)..repointTo(-1);
      expect(manager.currentIndex, -1);
      expect(manager.currentItem, isNull);
      expect(manager.canGoNext, isFalse);
      expect(manager.canGoPrevious, isFalse);
    });

    test('a playback ID is found at its position', () {
      final manager = managerOf(4);
      expect(manager.indexOfPlaybackId(thirdItem), 2);
      expect(manager.indexOfPlaybackId('absent'), -1);
    });
  });

  group('warmWindow', () {
    // Ported from the example app's queue, with its measured rules intact:
    // warm both directions, interleaved outward, forward preferred at equal
    // distance. Forward-only warming leaves the previous item a guaranteed
    // cold start, and the warming subsystem truncates to its own window.
    List<String> window(FastPixPlaylistManager manager, {int radius = 2}) =>
        manager.warmWindow(radius: radius).map((s) => s.playbackId).toList();

    test('interleaves outward, forward first at equal distance', () {
      final manager = managerOf(6, startIndex: 2);
      expect(window(manager), <String>[
        'item-3',
        'item-1',
        'item-4',
        'item-0',
      ]);
    });

    test('truncates at the start of the list', () {
      final manager = managerOf(5);
      expect(window(manager), <String>['item-1', thirdItem]);
    });

    test('truncates at the end of the list', () {
      final manager = managerOf(5, startIndex: 4);
      expect(window(manager), <String>['item-3', thirdItem]);
    });

    test('a radius larger than the list yields every other item, once', () {
      final manager = managerOf(3, startIndex: 1);
      final result = window(manager, radius: 10);
      expect(result, <String>[thirdItem, 'item-0']);
      expect(result.toSet(), hasLength(result.length));
    });

    test('a radius of zero warms nothing', () {
      expect(window(managerOf(5, startIndex: 2), radius: 0), isEmpty);
    });

    test('nothing is warmed without an active position', () {
      final manager = managerOf(5)..repointTo(-1);
      expect(window(manager), isEmpty);
    });
  });

  group('FastPixPlaylistState', () {
    test('snapshots the cursor, and equal cursors compare equal', () {
      final manager = managerOf(3, startIndex: 1);
      final state = manager.state;
      expect(state.index, 1);
      expect(state.count, 3);
      expect(state.canGoNext, isTrue);
      expect(state.canGoPrevious, isTrue);
      expect(state.hasPlaylist, isTrue);
      expect(state.position, '2 of 3');
      // Two snapshots of the same cursor are the same value, so a host can
      // skip a rebuild when nothing changed.
      expect(state, manager.state);
      expect(state.hashCode, manager.state.hashCode);
    });

    test('the empty state reports no playlist', () {
      expect(FastPixPlaylistState.empty.hasPlaylist, isFalse);
      expect(FastPixPlaylistState.empty.position, '');
    });
  });

  group('the playlist enums', () {
    test('repeat modes and change reasons are the documented set', () {
      expect(FastPixPlaylistRepeatMode.values, <FastPixPlaylistRepeatMode>[
        FastPixPlaylistRepeatMode.off,
        FastPixPlaylistRepeatMode.one,
        FastPixPlaylistRepeatMode.all,
      ]);
      expect(
        FastPixPlaylistItemChangeReason.values,
        <FastPixPlaylistItemChangeReason>[
          FastPixPlaylistItemChangeReason.initial,
          FastPixPlaylistItemChangeReason.userJump,
          FastPixPlaylistItemChangeReason.autoAdvance,
          FastPixPlaylistItemChangeReason.repeat,
        ],
      );
    });
  });
}
