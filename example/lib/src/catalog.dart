import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'demo_seed.dart';
import 'models/demo_stream.dart';

/// The streams shown on the home screen.
///
/// Persisted to a JSON file. A real app would load this from its own backend;
/// the demo keeps it local so the OTT layout has something to lay out without
/// inventing playback IDs that do not resolve against the viewer's own account.
///
/// Persistence is not only convenience. Testing precaching means force-stopping
/// the app and replaying the *same* source: re-entering it by hand risks a
/// different `token`, which changes the URL and therefore the cache key — a
/// guaranteed miss that looks exactly like precaching not working.
class Catalog extends ChangeNotifier {
  Catalog._();

  static final Catalog instance = Catalog._();

  final List<DemoStream> _streams = <DemoStream>[];

  /// Playback IDs of streams that have been opened, most recent first.
  final List<String> _recentIds = <String>[];

  /// Where the viewer got to in each stream, by playback ID.
  ///
  /// Persisted with the catalogue, so "continue watching" survives a restart —
  /// which is the whole point of the row, and also what makes the hero banner
  /// worth looking at: it shows what you were last watching, at the position
  /// you left it.
  final Map<String, StreamProgress> _progress = <String, StreamProgress>{};

  File? _file;

  /// Read the saved catalog. Safe to call more than once.
  ///
  /// Never throws: a corrupt or unreadable store must leave the app usable
  /// with an empty catalog, not fail to start.
  Future<void> load() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = _file = File('${dir.path}/demo_catalog.json');
      if (!file.existsSync()) {
        await _seed();
        return;
      }

      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return;

      _streams
        ..clear()
        ..addAll(<DemoStream>[
          for (final entry in (decoded['streams'] as List<dynamic>? ?? const []))
            if (entry is Map<String, dynamic>)
              ?DemoStream.fromJson(entry),
        ]);
      _recentIds
        ..clear()
        ..addAll((decoded['recent'] as List<dynamic>? ?? const [])
            .whereType<String>());
      _progress
        ..clear()
        ..addAll(StreamProgress.decodeAll(decoded['progress']));
      notifyListeners();
    } catch (_) {
      // An unreadable store is an empty catalog, never a failed launch.
    }

    await _seed();
  }

  /// Populate from the seed.
  ///
  /// Normally this only ever fills an *empty* catalog, so a stream the viewer
  /// edited or deleted is never resurrected on the next launch.
  ///
  /// Local overrides — `assets/local/streams.txt` or the run command — are the
  /// exception and replace what was stored. They carry tokens, tokens expire,
  /// and a stored copy of yesterday's token would otherwise win by having got
  /// there first: the app would keep failing on a credential the file had
  /// already fixed.
  Future<void> _seed() async {
    // Loaded before the decision, because whether a local file exists is only
    // knowable after reading the bundle.
    final seeded = await DemoSeed.load();
    _logSeed(seeded);

    final overridden = DemoSeed.hasCommandLineIds || DemoSeed.hasLocalOverrides;
    if (_streams.isNotEmpty && !overridden) return;
    if (seeded.isEmpty) return;

    _streams
      ..clear()
      ..addAll(seeded);
    _persist();
    notifyListeners();
  }

  /// Say what was seeded, once, at launch.
  ///
  /// A DRM stream that fails because its token never reached the build looks
  /// exactly like one that fails because the asset is missing: the same 404,
  /// the same screen. The distinction is knowable before playback — a seeded
  /// entry either carries a token or it does not — so print it rather than
  /// leaving it to be guessed at from a player error.
  void _logSeed(List<DemoStream> seeded) {
    if (!kDebugMode) return;
    final source = DemoSeed.hasLocalOverrides
        ? 'local overrides applied'
        : 'no local overrides — shipped catalog only '
            '(add example/assets/local/streams.txt for tokened entries)';
    debugPrint('catalog seeded ${seeded.length} streams · $source');
    for (final stream in seeded.where((s) => s.drmEnabled || s.token != null)) {
      debugPrint(
        '  ${stream.title}: token=${stream.token != null} '
        'drmToken=${stream.drmToken != null} '
        'host=${stream.streamHost ?? "default"} '
        'drmHost=${stream.drmHost ?? "default"}',
      );
    }
  }

  /// Write the catalog out. Fire-and-forget; a failed write must not break the
  /// in-memory state the user is already looking at.
  void _persist() {
    final file = _file;
    if (file == null) return;
    try {
      file.writeAsStringSync(
        jsonEncode(<String, dynamic>{
          'streams': _streams.map((stream) => stream.toJson()).toList(),
          'recent': _recentIds,
          'progress': <String, dynamic>{
            for (final entry in _progress.entries)
              entry.key: entry.value.toJson(),
          },
        }),
      );
    } catch (_) {}
  }

  List<DemoStream> get streams => List<DemoStream>.unmodifiable(_streams);

  bool get isEmpty => _streams.isEmpty;

  /// The stream featured in the hero banner, or null when nothing is added.
  ///
  /// Whatever was watched most recently, falling back to the first entry until
  /// something has been. It used to be `_streams.first` unconditionally, which
  /// meant the banner showed the first stream ever added and never changed —
  /// playing something moved it to the front of the *Continue watching* row
  /// while the top of the screen carried on advertising a different video.
  DemoStream? get featured {
    final watched = continueWatching;
    if (watched.isNotEmpty) return watched.first;
    return _streams.isEmpty ? null : _streams.first;
  }

  List<DemoStream> get live =>
      _streams.where((stream) => stream.isLive).toList(growable: false);

  List<DemoStream> get onDemand =>
      _streams.where((stream) => !stream.isLive).toList(growable: false);

  /// Streams that have been watched, in the order they were last opened.
  List<DemoStream> get continueWatching {
    final result = <DemoStream>[];
    for (final String id in _recentIds) {
      final index = _streams.indexWhere((stream) => stream.playbackId == id);
      if (index >= 0) result.add(_streams[index]);
    }
    return result;
  }

  /// Add [stream], or replace the existing entry with the same playback ID.
  void save(DemoStream stream) {
    final index = _streams.indexWhere(
      (existing) => existing.playbackId == stream.playbackId,
    );
    if (index >= 0) {
      _streams[index] = stream;
    } else {
      _streams.add(stream);
    }
    _persist();
    notifyListeners();
  }

  void remove(DemoStream stream) {
    _streams.removeWhere(
      (existing) => existing.playbackId == stream.playbackId,
    );
    _recentIds.remove(stream.playbackId);
    _progress.remove(stream.playbackId);
    _persist();
    notifyListeners();
  }

  void markWatched(DemoStream stream) => markWatchedId(stream.playbackId);

  /// Same, by playback ID.
  ///
  /// What the watch screen uses: once a playlist is playing, the player
  /// reports which item is active by playback ID, and the app has no reason to
  /// map that back to a catalogue object just to record it.
  void markWatchedId(String playbackId) {
    _recentIds
      ..remove(playbackId)
      ..insert(0, playbackId);
    _persist();
    notifyListeners();
  }

  /// Position of [stream] in the catalog, used to pick its poster gradient so
  /// a card keeps the same colours wherever it appears.
  int indexOf(DemoStream stream) =>
      _streams.indexWhere((existing) => existing.playbackId == stream.playbackId);

  /// How far through [playbackId] the viewer is, or null when unknown.
  StreamProgress? progressOf(String playbackId) => _progress[playbackId];

  /// Record where playback has reached.
  ///
  /// Called on a throttle rather than on every tick: this writes to disk and
  /// notifies, and a progress tick fires several times a second.
  void recordProgress(
    String playbackId,
    Duration position,
    Duration duration,
  ) {
    if (duration <= Duration.zero) return;
    final existing = _progress[playbackId];
    if (existing != null &&
        existing.position == position &&
        existing.duration == duration) {
      return;
    }
    _progress[playbackId] = StreamProgress(
      position: position,
      duration: duration,
    );
    _persist();
    notifyListeners();
  }

  /// Forget where playback reached — used when a video finishes, so it offers
  /// to play from the start next time rather than resuming two seconds from
  /// the end.
  void clearProgress(String playbackId) {
    if (_progress.remove(playbackId) == null) return;
    _persist();
    notifyListeners();
  }

  /// Where opening [playbackId] should resume from, or null to start at the
  /// beginning.
  Duration? resumePositionOf(String playbackId) =>
      _progress[playbackId]?.resumePosition;
}

/// How far through a stream the viewer got, and how long it is.
///
/// The duration is stored alongside the position because the hero banner needs
/// both — a bare position cannot say whether it is a quarter of the way in or
/// almost over — and because it is known at the moment the position is.
class StreamProgress {
  const StreamProgress({required this.position, required this.duration});

  /// Where playback had reached.
  final Duration position;

  /// How long the media is.
  final Duration duration;

  /// Ignore a position this early: the viewer has effectively not started, and
  /// offering to resume four seconds in is noise.
  static const Duration _minimumToResume = Duration(seconds: 5);

  /// Treat a position this close to the end as finished, so a stream that ran
  /// to completion offers a fresh play rather than resuming at the credits.
  static const Duration _endThreshold = Duration(seconds: 10);

  /// Whether there is a meaningful position to go back to.
  bool get isResumable =>
      position >= _minimumToResume && position + _endThreshold < duration;

  /// Where to resume, or null when the position is not worth returning to.
  Duration? get resumePosition => isResumable ? position : null;

  /// How much is left to watch.
  Duration get remaining {
    final left = duration - position;
    return left.isNegative ? Duration.zero : left;
  }

  /// Fraction watched, 0..1, for a progress bar.
  double get fraction {
    if (duration <= Duration.zero) return 0;
    final value = position.inMilliseconds / duration.inMilliseconds;
    return value.clamp(0.0, 1.0);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'position': position.inMilliseconds,
    'duration': duration.inMilliseconds,
  };

  /// Rebuild the whole map, skipping anything unreadable so one bad entry
  /// cannot stop the catalogue loading.
  static Map<String, StreamProgress> decodeAll(Object? decoded) {
    if (decoded is! Map) return <String, StreamProgress>{};
    final result = <String, StreamProgress>{};
    for (final entry in decoded.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String || value is! Map) continue;
      final position = value['position'];
      final duration = value['duration'];
      if (position is! int || duration is! int) continue;
      result[key] = StreamProgress(
        position: Duration(milliseconds: position),
        duration: Duration(milliseconds: duration),
      );
    }
    return result;
  }
}
