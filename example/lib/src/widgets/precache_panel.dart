import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';

import '../precache_probe.dart';

/// Trigger precaching and see what it did.
///
/// Precaching is invisible by design — it helps a *later* session — so this is
/// the only place its behaviour surfaces. It cannot prove the bytes landed:
/// the platform reports no completion, so the status means "asked for", never
/// "available". Use `adb logcat | grep CacheWorker` for that.
class PrecachePanel extends StatefulWidget {
  const PrecachePanel({super.key, required this.dataSource});

  final FastPixPlayerDataSource dataSource;

  @override
  State<PrecachePanel> createState() => _PrecachePanelState();
}

class _PrecachePanelState extends State<PrecachePanel> {
  bool _busy = false;

  Future<void> _precache() async {
    setState(() => _busy = true);
    await FastPixPrecacheManager.instance.precacheManifest(widget.dataSource);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.dataSource.playbackId;

    return ListenableBuilder(
      listenable: PrecacheProbe.instance,
      builder: (context, _) {
        final probe = PrecacheProbe.instance;
        final status = probe.statusOf(id);
        final working = probe.isWorking(id);
        final detail = probe.detailOf(id);

        final (Color color, String label) = switch (status) {
          FastPixPrecacheStatus.cached => (
            const Color(0xFF2C6A4A),
            'CACHED',
          ),
          FastPixPrecacheStatus.failed => (const Color(0xFF8F2F2F), 'FAILED'),
          FastPixPrecacheStatus.unsupported => (
            const Color(0xFF6A7280),
            'UNSUPPORTED',
          ),
          FastPixPrecacheStatus.idle => (
            const Color(0xFF3A414C),
            working ? 'WORKING' : 'NOT CACHED',
          ),
        };

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'PRECACHE · $label',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _busy || working ? null : _precache,
                  icon: const Icon(Icons.download_for_offline_outlined,
                      size: 16),
                  label: const Text('Precache'),
                ),
              ],
            ),
            if (detail != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  detail,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Color(0xFF929BA8),
                    height: 1.4,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
