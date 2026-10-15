import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fastpix_player_example/src/custom_ui/fastpix_seek_bar.dart';

/// A controller with no duration yet — what every video looks like while it
/// loads, and what a failed one looks like for good — playing [source].
class _NoDurationController extends FastPixPlayerController {
  _NoDurationController(this._source);

  final FastPixPlayerDataSource _source;

  @override
  FastPixPlayerDataSource? get dataSource => _source;

  @override
  FastPixPlaybackState get playbackState => FastPixPlaybackState.initial;
}

/// The seek bar used to print LIVE whenever the duration was zero, so an
/// on-demand video read as a live stream until it loaded — and forever if it
/// failed.
void main() {
  Future<void> pump(WidgetTester tester, StreamType type) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FastPixSeekBar(
              controller: _NoDurationController(
                FastPixPlayerDataSource.hls(playbackId: 'a', streamType: type),
              ),
            ),
          ),
        ),
      );

  testWidgets('an on-demand video with no duration yet is not LIVE', (
    tester,
  ) async {
    await pump(tester, StreamType.onDemand);
    expect(find.text('LIVE'), findsNothing);
    expect(find.text('--:--'), findsOneWidget);
  });

  testWidgets('a live stream is LIVE', (tester) async {
    await pump(tester, StreamType.live);
    expect(find.text('LIVE'), findsOneWidget);
  });
}
