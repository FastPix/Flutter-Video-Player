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

  /// Playback IDs the viewer deleted, so the seed does not bring them back.
  ///
  /// The seed is re-read on every launch, and without this a seeded stream
  /// the viewer deleted reappeared the next time the app opened.
  final Set<String> _removedIds = <String>{};

  /// The credentials the seed last applied to each stream, by playback ID.
  ///
  /// Seeding runs on every launch, and it used to copy the seed's token,
  /// licence token and hosts over the stored ones every time — so a token
  /// edited in the app was the seed's again the next time the app opened.
  /// With this record a launch applies only what the seed has *changed* since
  /// it last applied it: an edit survives, and a refreshed seed file still
  /// reaches a stream saved with yesterday's token.
  final Map<String, SeedCredentials> _seedApplied = <String, SeedCredentials>{};

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
      _removedIds
        ..clear()
        ..addAll((decoded['removed'] as List<dynamic>? ?? const [])
            .whereType<String>());
      _seedApplied
        ..clear()
        ..addAll(SeedCredentials.decodeAll(decoded['seedApplied']));
      notifyListeners();
    } catch (_) {
      // An unreadable store is an empty catalog, never a failed launch.
    }

    await _seed();
  }

  /// Populate from the seed.
  ///
  /// An empty catalog is filled from it. A stored one is only *merged* with
  /// it, and only when local overrides are present — see [mergeSeed].
  Future<void> _seed() async {
    // Loaded before the decision, because whether a local file exists is only
    // knowable after reading the bundle.
    final seeded = await DemoSeed.load();
    _logSeed(seeded);

    final merged = mergeSeed(
      stored: _streams,
      seeded: seeded,
      removed: _removedIds,
      overridden: DemoSeed.hasCommandLineIds || DemoSeed.hasLocalOverrides,
      applied: _seedApplied,
    );
    if (merged == null) return;

    _streams
      ..clear()
      ..addAll(merged);
    // What the seed says now is what the next launch compares against.
    for (final stream in seeded) {
      _seedApplied[stream.playbackId] = SeedCredentials.of(stream);
    }
    _persist();
    notifyListeners();
  }

  /// The catalog after launch-time seeding, or null to leave it as stored.
  ///
  /// - An empty catalog takes the whole seed, less anything the viewer
  ///   deleted.
  /// - A stored catalog is left alone unless local overrides are present.
  /// - With overrides, the stored catalog is kept — in its own order, with the
  ///   streams the viewer added and without the ones they deleted. A seeded
  ///   stream it already holds takes those of the seed's credentials and hosts
  ///   that differ from what [applied] says the seed last gave it, and a
  ///   seeded stream it has never held is appended.
  ///
  /// [applied] is what the seed last put on each stream. A value the seed
  /// still carries unchanged is not applied again, so a token edited in the
  /// app since is kept; a value it has changed is applied. A stream with no
  /// record takes every value the seed has, as it always did.
  ///
  /// Overrides used to *replace* the stored catalog outright. They carry
  /// tokens, tokens expire, and a stored copy of yesterday's token must not
  /// win by having got there first — but replacing everything to refresh a
  /// token also discarded every stream added in the app and resurrected every
  /// one deleted, on every launch. Refreshing credentials is all the override
  /// needs to do.
  @visibleForTesting
  static List<DemoStream>? mergeSeed({
    required List<DemoStream> stored,
    required List<DemoStream> seeded,
    required Set<String> removed,
    required bool overridden,
    Map<String, SeedCredentials> applied = const <String, SeedCredentials>{},
  }) {
    final wanted = seeded
        .where((stream) => !removed.contains(stream.playbackId))
        .toList();

    if (stored.isEmpty) return wanted.isEmpty ? null : wanted;
    if (!overridden || wanted.isEmpty) return null;

    final byId = <String, DemoStream>{
      for (final stream in wanted) stream.playbackId: stream,
    };
    final merged = <DemoStream>[
      for (final stream in stored)
        byId.containsKey(stream.playbackId)
            ? _withSeedCredentials(
                stream,
                byId[stream.playbackId]!,
                applied[stream.playbackId],
              )
            : stream,
    ];
    final storedIds = {for (final stream in stored) stream.playbackId};
    merged.addAll(
      wanted.where((stream) => !storedIds.contains(stream.playbackId)),
    );
    return merged;
  }

  /// [stored] with [seed]'s tokens and hosts, keeping what the viewer edited.
  ///
  /// A field the seed leaves blank keeps the stored value rather than
  /// clearing it, and so does a field the seed carries unchanged since
  /// [previous] — the value it last applied — because the stored value may be
  /// the viewer's edit of it. With no [previous], every value the seed has is
  /// applied.
  static DemoStream _withSeedCredentials(
    DemoStream stored,
    DemoStream seed,
    SeedCredentials? previous,
  ) {
    // Null leaves the stored field as it is.
    String? changed(String? now, String? before) =>
        previous != null && now == before ? null : now;
    final drmToken = changed(seed.drmToken, previous?.drmToken);
    return stored.copyWith(
      token: changed(seed.token, previous?.token),
      drmToken: drmToken,
      streamHost: changed(seed.streamHost, previous?.streamHost),
      drmHost: changed(seed.drmHost, previous?.drmHost),
      // Only ever switched on: the seed's DRM flag follows its licence token,
      // and a seed line without one says nothing about the stored stream.
      // Switched on only with a licence token it is applying, so DRM switched
      // off in the app stays off while the seed is unchanged.
      drmEnabled: seed.drmEnabled && drmToken != null ? true : null,
    );
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
          'removed': _removedIds.toList(),
          'seedApplied': <String, dynamic>{
            for (final entry in _seedApplied.entries)
              entry.key: entry.value.toJson(),
          },
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
    // Adding a stream back undoes deleting it.
    _removedIds.remove(stream.playbackId);
    _persist();
    notifyListeners();
  }

  void remove(DemoStream stream) {
    _streams.removeWhere(
      (existing) => existing.playbackId == stream.playbackId,
    );
    _recentIds.remove(stream.playbackId);
    _progress.remove(stream.playbackId);
    _removedIds.add(stream.playbackId);
    _persist();
    notifyListeners();
  }

  /// Take [playbackId] off *Continue watching*, and forget where it had
  /// reached, while leaving it in the catalog — and so in *On demand*.
  ///
  /// The two rows answer different questions: *On demand* is what the app
  /// has, *Continue watching* is what the viewer has been watching. Clearing
  /// your history must not delete the video; that is [remove].
  void removeFromContinueWatching(String playbackId) {
    final removed = _recentIds.remove(playbackId);
    final forgotten = _progress.remove(playbackId) != null;
    if (!removed && !forgotten) return;
    _persist();
    notifyListeners();
  }

  /// Whether [playbackId] is on *Continue watching*.
  bool isInContinueWatching(String playbackId) =>
      _recentIds.contains(playbackId);

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

/// The credentials the seed last put on a stream: what launch-time seeding
/// compares the seed against, so that it applies only what the seed *changed*.
///
/// Without it every launch copied the seed's credentials over the stored
/// ones, and a token the viewer had edited in the app was back to the seed's
/// the next time the app opened. Only the credential fields are recorded,
/// because only they are taken from the seed.
@immutable
class SeedCredentials {
  const SeedCredentials({
    this.token,
    this.drmToken,
    this.streamHost,
    this.drmHost,
  });

  /// The credentials [stream] carries.
  SeedCredentials.of(DemoStream stream)
    : token = stream.token,
      drmToken = stream.drmToken,
      streamHost = stream.streamHost,
      drmHost = stream.drmHost;

  final String? token;
  final String? drmToken;
  final String? streamHost;
  final String? drmHost;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'token': token,
    'drmToken': drmToken,
    'streamHost': streamHost,
    'drmHost': drmHost,
  };

  /// Rebuild the whole map, skipping anything unreadable so one bad entry
  /// cannot stop the catalogue loading.
  static Map<String, SeedCredentials> decodeAll(Object? decoded) {
    if (decoded is! Map) return <String, SeedCredentials>{};
    String? text(Object? value) => value is String ? value : null;
    return <String, SeedCredentials>{
      for (final entry in decoded.entries)
        if (entry.key is String && entry.value is Map)
          entry.key as String: SeedCredentials(
            token: text((entry.value as Map)['token']),
            drmToken: text((entry.value as Map)['drmToken']),
            streamHost: text((entry.value as Map)['streamHost']),
            drmHost: text((entry.value as Map)['drmHost']),
          ),
    };
  }
}
