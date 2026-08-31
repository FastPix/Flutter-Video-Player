import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';

import '../preload_probe.dart';

/// Shows whether this playback started warm or cold.
///
/// The whole point of the feature is invisible by design — both paths render
/// the same video — so this is the only thing on screen that distinguishes a
/// working preload from a broken one.
class WarmStartBadge extends StatelessWidget {
  const WarmStartBadge({super.key, required this.playbackId});

  final String playbackId;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: PreloadProbe.instance,
      builder: (context, _) {
        final adopted = PreloadProbe.instance.wasAdopted(playbackId);
        final elapsed = PreloadProbe.instance.readyIn(playbackId);
        return _Pill(
          color: adopted ? const Color(0xFF2C6A4A) : const Color(0xFF3A414C),
          icon: adopted ? Icons.bolt_rounded : Icons.hourglass_empty_rounded,
          label: adopted
              ? 'WARM START${elapsed == null ? '' : ' · warmed in ${elapsed.inMilliseconds}ms'}'
              : 'COLD START',
        );
      },
    );
  }
}

/// Per-title warm state, for the home screen.
class PreloadStatusDot extends StatelessWidget {
  const PreloadStatusDot({super.key, required this.playbackId});

  final String playbackId;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: PreloadProbe.instance,
      builder: (context, _) {
        final status = PreloadProbe.instance.statusOf(playbackId);
        final (Color color, String label) = switch (status) {
          FastPixPreloadStatus.ready => (const Color(0xFF2C6A4A), 'warm'),
          FastPixPreloadStatus.loading => (const Color(0xFFA8590A), 'warming'),
          FastPixPreloadStatus.failed => (const Color(0xFF8F2F2F), 'failed'),
          FastPixPreloadStatus.cancelled => (const Color(0xFF6A7280), 'dropped'),
          FastPixPreloadStatus.queued => (const Color(0xFF3A414C), 'cold'),
        };
        return _Pill(color: color, label: label);
      },
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.color, required this.label, this.icon});

  final Color color;
  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 13, color: Colors.white),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}

/// Live feed of every preload event. Opened from the watch screen.
class PreloadDebugSheet extends StatelessWidget {
  const PreloadDebugSheet({super.key});

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(0xFF16191F),
    isScrollControlled: true,
    builder: (_) => const PreloadDebugSheet(),
  );

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListenableBuilder(
        listenable: PreloadProbe.instance,
        builder: (context, _) {
          final log = PreloadProbe.instance.log;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
                child: Row(
                  children: <Widget>[
                    const Expanded(
                      child: Text(
                        'Preload events',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: PreloadProbe.instance.reset,
                      child: const Text('Clear'),
                    ),
                  ],
                ),
              ),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.5,
                ),
                child: log.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.fromLTRB(16, 8, 16, 32),
                        child: Text(
                          'Nothing yet. Preloading starts from the home '
                          'screen — go back, then open a title.',
                          style: TextStyle(color: Color(0xFF929BA8), fontSize: 13),
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                        itemCount: log.length,
                        itemBuilder: (context, i) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Text(
                            log[i],
                            style: const TextStyle(
                              color: Color(0xFFC3C8D0),
                              fontFamily: 'monospace',
                              fontSize: 11.5,
                            ),
                          ),
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A compact card for the up-next rail, carrying its warm status.
///
/// The pill is the whole reason this widget exists rather than reusing
/// PosterCard: watching an upcoming item go `warming` -> `warm` while the
/// current video plays is the clearest demonstration the feature has.
class UpNextCard extends StatelessWidget {
  const UpNextCard({
    super.key,
    required this.playbackId,
    required this.title,
    required this.label,
    required this.onTap,
  });

  final String playbackId;
  final String title;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 168,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: const Color(0xFF1F242C),
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.all(8),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: PreloadStatusDot(playbackId: playbackId),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: const TextStyle(
                fontSize: 10,
                letterSpacing: 0.7,
                fontWeight: FontWeight.w700,
                color: Color(0xFF929BA8),
              ),
            ),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}
