import 'package:flutter/foundation.dart';

import 'models/demo_stream.dart';

/// Seeds the catalog from `.env` so the app has something to play without
/// anyone typing playback IDs in by hand.
///
/// ## Format
///
/// One playback ID per line. Blank lines and `#` comments are ignored, so the
/// file can be annotated. A line may optionally carry a title and a token,
/// comma-separated, for streams that need one:
///
/// ```
/// # unprotected
/// 6d75bc7a-6ef7-4b20-ad0e-b11f11bab3e6
/// 6dfe8ed6-c83e-4791-a3a8-29420e847011, Trailer
///
/// # signed
/// 13ee64af-28c8-43e8-a83d-e9308a83eec8, Protected, eyJhbGciOi…
/// ```
///
/// ## Why seeding matters here specifically
///
/// Precaching is only observable by replaying the **same** source across app
/// restarts. Re-entering a stream by hand risks a different token, which is a
/// different URL and therefore a different cache key — a guaranteed miss that
/// looks exactly like precaching being broken when the test was at fault.
/// Seeding from a file removes that whole class of false negative.
class DemoSeed {
  const DemoSeed._();

  /// Playback IDs supplied on the run command, comma-separated.
  ///
  /// ```
  /// flutter run --dart-define=FASTPIX_PLAYBACK_IDS=id-one,id-two
  /// ```
  ///
  /// Takes precedence over [_asset], so a throwaway set of IDs can be tried
  /// without editing a file that is bundled into the build. Values are fixed
  /// when the command runs — `String.fromEnvironment` is a compile-time
  /// constant, not something read from the device at launch.
  static const String _defined = String.fromEnvironment('FASTPIX_PLAYBACK_IDS');

  /// The catalog the demo ships with.
  ///
  /// Committed deliberately. These are **public playback IDs**, not secrets —
  /// they identify assets, they do not authorise access to them — so keeping
  /// them here means the demo works on a fresh clone with no setup, on any
  /// machine, in CI, and from a release APK.
  ///
  /// They are not read from `.env`. That file is gitignored, and a declared
  /// asset that is missing is a **build failure**, not a graceful degradation
  /// — so a bundled `.env` would break every checkout that did not have one.
  /// Bundling it would also place its contents inside the APK, where anything
  /// added to it later (a playback token, say) would be extractable.
  ///
  /// Override without touching this list:
  /// ```
  /// flutter run --dart-define=FASTPIX_PLAYBACK_IDS=id-one,id-two
  /// ```
  static const List<String> defaultPlaybackIds = <String>[
    '6d75bc7a-6ef7-4b20-ad0e-b11f11bab3e6',
    '6dfe8ed6-c83e-4791-a3a8-29420e847011',
    'c47238ad-97d1-4469-a302-b29e01252d28',
    '61b06e3f-e23c-471e-a5be-a3ab9c20d121',
    'aedaa7c7-d0a7-4ce8-8a0b-54d7b2c6c85d',
    'fffca268-393e-4c26-ba15-6465bd088e5b',
    'e4f7b73c-0f69-4eb6-a916-afd56d1bc513',
    '76a15ba8-7db2-4c72-b9e0-e15c454f4d9b',
    'cfe6b001-3d32-499b-8571-f7843ce3fd37',
    '73268d35-c6ee-4ac5-abb1-880fe857850d',
    'ff063494-d1fc-4ade-bf90-beb83246b46c',
  ];

  /// Whether IDs were supplied on the run command.
  ///
  /// When they were, they **replace** a stored catalog rather than deferring to
  /// it: naming IDs on the command line is unambiguous intent, and the usual
  /// "never overwrite what the user saved" rule would otherwise mean the flag
  /// silently did nothing on any device that had been run before.
  static bool get hasCommandLineIds => _defined.isNotEmpty;

  /// Streams declared in `.env`, or an empty list when it is missing or empty.
  ///
  /// Never throws: a malformed or absent file leaves the catalog empty and the
  /// app usable, exactly as it was before seeding existed.
  static Future<List<DemoStream>> load() async {
    // Command line wins; otherwise the shipped list.
    final raw = _defined.isNotEmpty
        ? _defined.split(',').map((id) => id.trim()).join('\n')
        : defaultPlaybackIds.join('\n');
    return parse(raw);
  }

  /// Turn the file's text into streams.
  ///
  /// Split out from [load] so the format is testable without a bundle or a
  /// device — the parsing is where a stray blank line or duplicate silently
  /// costs you a stream, and that is worth locking down.
  @visibleForTesting
  static List<DemoStream> parse(String raw) {
    final streams = <DemoStream>[];
    final seen = <String>{};

    for (final line in raw.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;

      final parts = trimmed.split(',').map((part) => part.trim()).toList();
      final id = parts.first;
      if (id.isEmpty) continue;
      // A repeated ID would produce two catalog entries pointing at one asset,
      // which makes preload window behaviour confusing to read in the logs.
      if (!seen.add(id)) continue;

      final title = parts.length > 1 && parts[1].isNotEmpty ? parts[1] : id;
      final token = parts.length > 2 && parts[2].isNotEmpty ? parts[2] : null;

      streams.add(
        DemoStream(
          playbackId: id,
          title: title,
          token: token,
          // A token alone does not imply DRM — plenty of signed streams are
          // unprotected — so DRM stays off unless a stream is edited in the
          // app to add a licence token.
          drmEnabled: false,
        ),
      );
    }

    return streams;
  }
}
