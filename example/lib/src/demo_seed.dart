import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'models/demo_stream.dart';

/// Seeds the catalog from `.env` so the app has something to play without
/// anyone typing playback IDs in by hand.
///
/// ## Format
///
/// One playback ID per line. Blank lines and `#` comments are ignored, so the
/// file can be annotated. A line may optionally carry a title, a playback
/// token and a DRM licence token, comma-separated:
///
/// ```
/// id, title, token, drmToken, host, drmHost
/// ```
///
/// ```
/// # unprotected
/// 6d75bc7a-6ef7-4b20-ad0e-b11f11bab3e6
/// 6dfe8ed6-c83e-4791-a3a8-29420e847011, Trailer
///
/// # signed, but not protected
/// 13ee64af-28c8-43e8-a83d-e9308a83eec8, Protected, eyJhbGciOi…
///
/// # DRM: the fourth field is the licence token, and its presence is what
/// # turns DRM on
/// 12f8d4d9-3b03-433c-997b-76d740d621ad, DRM prod, eyJwbGF5…, eyJkcm0i…
///
/// # An asset in another environment: the fifth field is the playback host and
/// # the sixth the DRM host. Blank fields fall back to the package defaults,
/// # so a production stream needs neither.
/// c29dfdd1-…, DRM staging, eyJwbGF5…, eyJkcm0i…, stream.fastpix.com, api.fastpix.com
/// ```
///
/// Set the two hosts together. FastPix serves the manifest and the licence
/// from different origins but the *same* environment, and a staging manifest
/// with a production licence server fails at the DRM handshake — which reads
/// like a bad token rather than a wrong host.
///
/// ## Where the lines come from
///
/// Three sources, in precedence order — a line wins over one with the same ID
/// below it:
///
/// 1. `assets/local/streams.txt`, read at launch. Gitignored, so this is where
///    tokens go, and it needs **no run flag** — which is what makes it the one
///    that works from Xcode, from Android Studio, and from a run button.
/// 2. `FASTPIX_EXTRA_PLAYBACK_IDS`, compiled in with
///    `--dart-define-from-file=.env`. Same purpose, but a define is fixed at
///    build time and silently absent from any launch that forgot the flag.
/// 3. [defaultCatalog], committed and tokenless.
///
/// Only the fourth field enables DRM. A playback token alone does not: plenty
/// of signed streams are unprotected, and guessing wrong there produces a
/// stream that fails in a way that looks like a DRM bug.
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

  /// Streams supplied on the run command, **semicolon**-separated.
  ///
  /// ```
  /// flutter run --dart-define=FASTPIX_PLAYBACK_IDS=id-one;id-two
  /// ```
  ///
  /// Semicolons, not commas, because a comma already separates the fields
  /// *within* an entry. So a full seed line can be given here — which is the
  /// only way to run a DRM stream without writing its licence token into a
  /// file:
  ///
  /// ```
  /// flutter run --dart-define='FASTPIX_PLAYBACK_IDS=12f8d4d9-…, DRM prod, <token>, <drmToken>'
  /// ```
  ///
  /// A credential passed this way is in your shell history and in the built
  /// binary, but not in git — which is the distinction that matters for a
  /// token that is meant to expire anyway.
  ///
  /// Takes precedence over [defaultCatalog], so a throwaway set can be tried
  /// without editing a committed file. Values are fixed when the command runs
  /// — `String.fromEnvironment` is a compile-time constant, not something read
  /// from the device at launch.
  static const String _defined = String.fromEnvironment('FASTPIX_PLAYBACK_IDS');

  /// Extra streams **added to** the shipped catalog, same format, also
  /// semicolon-separated.
  ///
  /// ```
  /// flutter run --dart-define-from-file=.env
  /// ```
  ///
  /// This is the seat for credentials. [defaultCatalog] may never carry a
  /// token, so a DRM stream cannot be shipped in it — and [_defined] *replaces*
  /// the catalog, so using that for one DRM entry costs you the other ten
  /// videos. This one merges: the shipped list keeps working and the tokened
  /// entries join it.
  ///
  /// Entries here are parsed **first**, so a line whose ID is already in
  /// [defaultCatalog] wins — which is what turns the committed, tokenless
  /// `drm staging` entries into playable ones rather than duplicating them.
  ///
  /// `.env` is gitignored, so the tokens stay out of the repo; they are still
  /// compiled into the binary, which is why they should be short-lived ones.
  static const String _extra =
      String.fromEnvironment('FASTPIX_EXTRA_PLAYBACK_IDS');

  /// Seed lines read from the bundle at launch, in [parse]'s own format —
  /// one entry per line, `#` comments and blank lines allowed.
  ///
  /// This is the path that needs nothing remembered at run time. A define is
  /// compiled in, so a launch from Xcode or a run button — which is how DRM
  /// gets tested, since FairPlay needs a real device — produces a binary with
  /// no tokens in it and DRM entries that 404, with nothing on screen saying
  /// why. An asset is read by the running app instead, so the same build works
  /// however it was started.
  ///
  /// The file is gitignored. It is still inside the APK or the .app, so it is
  /// extractable — use short-lived tokens, exactly as with a define.
  static const String _localAsset = 'assets/local/streams.txt';

  /// Whether the launch carried local overrides, set by [load].
  ///
  /// Read by `Catalog` to decide whether to re-seed a catalog it already has
  /// stored: these entries carry tokens that expire, so yesterday's stored copy
  /// has to give way to today's file rather than win by being there first.
  static bool hasLocalOverrides = false;

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
  /// Each entry is a seed line in the format [parse] reads: the playback ID,
  /// then a title. **Never a token** — the third field is a credential and has
  /// no business in a committed file, which `demo_seed_test` enforces. The DRM
  /// entries here are therefore listed but not playable on their own; their
  /// tokens come from [_extra], via a gitignored `.env`.
  ///
  /// The titles matter more than they look. Every place the app names a video
  /// — the catalog rows, the up-next rail, and now the playlist queue inside
  /// the player — reads [DemoStream.title], which [parse] falls back to the
  /// playback ID for when a line has no title. A list of bare IDs is why the
  /// queue used to be a column of UUIDs.
  ///
  /// Override without touching this list:
  /// ```
  /// flutter run --dart-define=FASTPIX_PLAYBACK_IDS=id-one,id-two
  /// ```
  static const List<String> defaultCatalog = <String>[
    '2125094c-db43-4748-90e1-18539f2ccf98, Multiple tracks',
    '6d75bc7a-6ef7-4b20-ad0e-b11f11bab3e6, Long video (1 hr)',
    '80ebde8a-8b3f-42a7-9d46-37abc11e4e34, One minute video',
    'c47238ad-97d1-4469-a302-b29e01252d28, Ten second video',
    '8bc12a9a-9796-412b-89c5-5ab66380e016, Big Buck Bunny',
    'fffca268-393e-4c26-ba15-6465bd088e5b, Product advertisement',
    'e4f7b73c-0f69-4eb6-a916-afd56d1bc513, Nature',
    '76a15ba8-7db2-4c72-b9e0-e15c454f4d9b, Magnificent view of Earth (4 hr)',
    'e5ce0dd5-e927-455e-ac4a-42044d0d1ed4, Thirty second video',
    '6ea06f51-03fa-4892-8469-eb98c241c048, Nature II',
    // No DRM entries here, deliberately. A protected stream needs a licence
    // token, a committed file may not carry one, and a DRM playback ID listed
    // without its token and its host is not a stream that half works — it is a
    // 404 that reads like a deleted asset. They live in `.env`, which supplies
    // all four fields at once. See [_extra].
  ];

  /// Whether IDs were supplied on the run command.
  ///
  /// When they were, they **replace** a stored catalog rather than deferring to
  /// it: naming IDs on the command line is unambiguous intent, and the usual
  /// "never overwrite what the user saved" rule would otherwise mean the flag
  /// silently did nothing on any device that had been run before.
  ///
  /// Also true for [_extra]: its whole point is a token that expires, so a
  /// stored catalog holding yesterday's token must be refreshed on launch
  /// rather than kept.
  static bool get hasCommandLineIds => _defined.isNotEmpty || _extra.isNotEmpty;

  /// Streams declared in `.env`, or an empty list when it is missing or empty.
  ///
  /// Never throws: a malformed or absent file leaves the catalog empty and the
  /// app usable, exactly as it was before seeding existed.
  static Future<List<DemoStream>> load() async {
    // Command line wins; otherwise the shipped list.
    final base = _defined.isNotEmpty
        ? _split(_defined)
        : defaultCatalog.map((entry) => entry.trim()).toList();

    final local = await _localLines();
    hasLocalOverrides = local.isNotEmpty || _extra.isNotEmpty;

    // Overrides go in front so a tokened line beats the tokenless one carrying
    // the same ID — parse() keeps the first entry for an ID and drops the rest.
    final raw = <String>[...local, ..._split(_extra), ...base].join('\n');
    return parse(raw);
  }

  /// Read [_localAsset], or nothing at all.
  ///
  /// A missing file is the normal case on a fresh clone and must not be an
  /// error: the app falls back to the shipped catalog and stays usable.
  static Future<List<String>> _localLines() async {
    try {
      final raw = await rootBundle.loadString(_localAsset);
      return raw.split('\n').map((line) => line.trim()).toList();
    } catch (_) {
      // Absent, unreadable, or read before the binding exists (unit tests).
      return const <String>[];
    }
  }

  /// Split a semicolon-separated define into seed lines.
  static List<String> _split(String value) => value
      .split(';')
      .map((entry) => entry.trim())
      .where((entry) => entry.isNotEmpty)
      .toList();

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

      final parts =
          trimmed.split(',').map((part) => _unquote(part.trim())).toList();
      final id = parts.first;
      if (id.isEmpty) continue;
      // A repeated ID would produce two catalog entries pointing at one asset,
      // which makes preload window behaviour confusing to read in the logs.
      if (!seen.add(id)) continue;

      String? field(int index) =>
          parts.length > index && parts[index].isNotEmpty ? parts[index] : null;

      final title = field(1) ?? id;
      final token = field(2);
      final drmToken = field(3);
      final host = field(4);
      final drmHost = field(5);

      streams.add(
        DemoStream(
          playbackId: id,
          title: title,
          streamHost: host,
          drmHost: drmHost,
          token: token,
          drmToken: drmToken,
          // The licence token is what says DRM, not the playback token: plenty
          // of signed streams are unprotected. And a stream marked DRM with no
          // licence token is worse than one not marked at all — `toDataSource`
          // builds no DRM configuration for it, so it reaches the player as an
          // encrypted stream with nothing to decrypt it.
          drmEnabled: drmToken != null,
        ),
      );
    }

    return streams;
  }

  /// Strip one layer of matching quotes.
  ///
  /// Seed lines are usually pasted from somewhere they were quoted — a Dart
  /// list, a shell command — and a title of `'Nature'` complete with the
  /// apostrophes is not what anyone meant. Unmatched quotes are left alone;
  /// they may be part of the text.
  static String _unquote(String value) {
    if (value.length < 2) return value;
    final first = value[0];
    if (first != "'" && first != '"') return value;
    return value.endsWith(first) ? value.substring(1, value.length - 1) : value;
  }
}
