import 'package:fastpix_player_example/main.dart';
import 'package:fastpix_player_example/src/catalog.dart';
import 'package:fastpix_player_example/src/models/demo_stream.dart';
import 'package:fastpix_player_example/src/widgets/stream_form_sheet.dart';
import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The catalog is an app-wide singleton, so each test starts from a clean one.
  tearDown(() {
    for (final stream in Catalog.instance.streams) {
      Catalog.instance.remove(stream);
    }
  });

  testWidgets('empty catalog offers a way to add a stream', (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();

    expect(find.text('Your catalog is empty'), findsOneWidget);
    expect(find.text('Add a stream'), findsOneWidget);
  });

  testWidgets('a saved stream becomes the hero', (tester) async {
    Catalog.instance.save(
      const DemoStream(playbackId: 'abc123', title: 'Rocket Launch'),
    );

    await tester.pumpWidget(const MyApp());
    await tester.pump();

    expect(find.text('Your catalog is empty'), findsNothing);
    expect(find.text('Rocket Launch'), findsWidgets);
    expect(find.text('Play'), findsOneWidget);
  });

  testWidgets('the add sheet requires a playback ID', (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();

    await tester.tap(find.text('Add a stream'));
    await tester.pumpAndSettle();

    // The submit button sits at the end of the sheet's own scroll view, which
    // has to be named — the home screen behind it is scrollable too.
    await tester.scrollUntilVisible(
      find.text('Add to catalog'),
      200,
      scrollable: find
          .descendant(
            of: find.byType(StreamFormSheet),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.text('Add to catalog'));
    await tester.pump();

    expect(find.text('A playback ID is required'), findsOneWidget);
    expect(Catalog.instance.isEmpty, isTrue);
  });

  group('DemoStream', () {
    test('routes DRM only when it is switched on', () {
      const withToken = DemoStream(
        playbackId: 'abc',
        title: 'Clear stream',
        drmToken: 'leftover-token',
      );

      // A leftover token must not turn clear media into a DRM load; that
      // routes it through Widevine/FairPlay and it never plays.
      expect(withToken.toDataSource().drmEnabled, isFalse);
      expect(
        withToken.copyWith(drmEnabled: true).toDataSource().drmEnabled,
        isTrue,
      );
    });

    test('leaves the host unset when blank, for the package default', () {
      const stream = DemoStream(
        playbackId: 'abc',
        title: 'Default host',
        streamHost: '',
      );

      expect(stream.toDataSource().customDomain, isNull);
    });

    // `toDataSource` is the only seam between the catalogue and the player:
    // once a playlist is set, the up-next rail renders from the *sources* the
    // player holds, so anything the rail shows has to survive this conversion.
    // These two assertions moved here when `PlaybackQueue` was deleted — the
    // playlist itself now lives in the SDK.
    test('carries the fields the up-next rail renders', () {
      const stream = DemoStream(
        playbackId: 'abc',
        title: 'Episode 1',
        description: 'The first one',
        isLive: true,
      );

      final source = stream.toDataSource();
      expect(source.title, 'Episode 1');
      expect(source.description, 'The first one');
      expect(source.streamType, StreamType.live);
    });

    test('converts a catalogue list in order', () {
      const catalogue = <DemoStream>[
        DemoStream(playbackId: 'v0', title: 'v0'),
        DemoStream(playbackId: 'v1', title: 'v1'),
        DemoStream(playbackId: 'v2', title: 'v2'),
      ];

      expect(
        <FastPixPlayerDataSource>[
          for (final stream in catalogue) stream.toDataSource(),
        ].map((source) => source.playbackId),
        <String>['v0', 'v1', 'v2'],
      );
    });
  });
}
