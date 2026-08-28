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
      notifyListeners();
    } catch (_) {
      // An unreadable store is an empty catalog, never a failed launch.
    }

    // Seed when there is nothing to show, or when IDs were named on the run
    // command — the latter replaces whatever was stored, because otherwise the
    // flag appears to do nothing on any device that has been run before.
    if (_streams.isEmpty || DemoSeed.hasCommandLineIds) await _seed();
  }

  /// Populate from `.env` on first run.
  ///
  /// Only ever fills an empty catalog, so a stream the user edited or deleted
  /// is never resurrected on the next launch.
  Future<void> _seed() async {
    final seeded = await DemoSeed.load();
    if (seeded.isEmpty) return;

    _streams
      ..clear()
      ..addAll(seeded);
    _persist();
    notifyListeners();
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
        }),
      );
    } catch (_) {}
  }

  List<DemoStream> get streams => List<DemoStream>.unmodifiable(_streams);

  bool get isEmpty => _streams.isEmpty;

  /// The stream featured in the hero banner, or null when nothing is added.
  DemoStream? get featured => _streams.isEmpty ? null : _streams.first;

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
    _persist();
    notifyListeners();
  }

  void markWatched(DemoStream stream) {
    _recentIds
      ..remove(stream.playbackId)
      ..insert(0, stream.playbackId);
    _persist();
    notifyListeners();
  }

  /// Position of [stream] in the catalog, used to pick its poster gradient so
  /// a card keeps the same colours wherever it appears.
  int indexOf(DemoStream stream) =>
      _streams.indexWhere((existing) => existing.playbackId == stream.playbackId);
}
