import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';

import '../models/demo_stream.dart';
import '../theme.dart';

/// Sheet for adding or editing a catalog entry.
///
/// Returns the saved [DemoStream], or null when dismissed.
class StreamFormSheet extends StatefulWidget {
  const StreamFormSheet({super.key, this.initial});

  final DemoStream? initial;

  static Future<DemoStream?> show(
    BuildContext context, {
    DemoStream? initial,
  }) {
    return showModalBottomSheet<DemoStream>(
      context: context,
      isScrollControlled: true,
      builder: (_) => StreamFormSheet(initial: initial),
    );
  }

  @override
  State<StreamFormSheet> createState() => _StreamFormSheetState();
}

class _StreamFormSheetState extends State<StreamFormSheet> {
  late final TextEditingController _playbackId;
  late final TextEditingController _title;
  late final TextEditingController _host;
  late final TextEditingController _token;
  late final TextEditingController _drmToken;
  late final TextEditingController _subtitleUrl;
  late final TextEditingController _subtitleLabel;
  late final TextEditingController _subtitleLanguage;

  late final TextEditingController _drmHost;
  late bool _drmEnabled;
  late bool _isLive;
  late bool _subtitlesOnByDefault;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    final subtitle =
        initial != null && initial.subtitles.isNotEmpty
            ? initial.subtitles.first
            : null;

    _playbackId = TextEditingController(text: initial?.playbackId ?? '');
    _title = TextEditingController(text: initial?.title ?? '');
    // Blank means the package default, stream.fastpix.com.
    _host = TextEditingController(
      text: initial?.streamHost ?? 'stream.fastpix.com',
    );
    // Blank means the package default, api.fastpix.com. It is prefilled from
    // the stream host's environment for a new stream, since the manifest and
    // the licence always come from the same one.
    _drmHost = TextEditingController(text: initial?.drmHost ?? '');
    _token = TextEditingController(text: initial?.token ?? '');
    _drmToken = TextEditingController(text: initial?.drmToken ?? '');
    _subtitleUrl = TextEditingController(text: subtitle?.url ?? '');
    _subtitleLabel = TextEditingController(text: subtitle?.name ?? '');
    _subtitleLanguage = TextEditingController(
      text: subtitle?.languageCode ?? '',
    );

    _drmEnabled = initial?.drmEnabled ?? false;
    _isLive = initial?.isLive ?? false;
    _subtitlesOnByDefault = initial?.subtitlesOnByDefault ?? false;
  }

  @override
  void dispose() {
    _playbackId.dispose();
    _title.dispose();
    _host.dispose();
    _drmHost.dispose();
    _token.dispose();
    _drmToken.dispose();
    _subtitleUrl.dispose();
    _subtitleLabel.dispose();
    _subtitleLanguage.dispose();
    super.dispose();
  }

  void _save() {
    final playbackId = _playbackId.text.trim();
    if (playbackId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A playback ID is required')),
      );
      return;
    }

    final subtitleUrl = _subtitleUrl.text.trim();
    final subtitles = <FastPixPlayerSubtitle>[
      if (subtitleUrl.isNotEmpty)
        FastPixPlayerSubtitle(
          url: subtitleUrl,
          name:
              _subtitleLabel.text.trim().isEmpty
                  ? 'Subtitles'
                  : _subtitleLabel.text.trim(),
          languageCode:
              _subtitleLanguage.text.trim().isEmpty
                  ? null
                  : _subtitleLanguage.text.trim(),
          isDefault: true,
        ),
    ];

    final title = _title.text.trim();
    final host = _host.text.trim();
    final token = _token.text.trim();
    final drmToken = _drmToken.text.trim();
    final drmHost = _drmHost.text.trim();

    Navigator.pop(
      context,
      DemoStream(
        playbackId: playbackId,
        title: title.isEmpty ? playbackId : title,
        streamHost: host.isEmpty ? null : host,
        drmHost: drmHost.isEmpty ? null : drmHost,
        token: token.isEmpty ? null : token,
        drmToken: drmToken.isEmpty ? null : drmToken,
        drmEnabled: _drmEnabled,
        isLive: _isLive,
        subtitles: subtitles,
        subtitlesOnByDefault: _subtitlesOnByDefault && subtitles.isNotEmpty,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.initial != null;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) {
          return ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                isEditing ? 'Edit stream' : 'Add a stream',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Use a playback ID that has reached "ready" in the FastPix '
                'dashboard.',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 24),

              const _SectionLabel('Source'),
              TextField(
                controller: _playbackId,
                decoration: const InputDecoration(labelText: 'Playback ID'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _title,
                decoration: const InputDecoration(
                  labelText: 'Title (optional)',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _host,
                decoration: const InputDecoration(
                  labelText: 'Stream host',
                  helperText: 'Blank uses stream.fastpix.com',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _token,
                decoration: const InputDecoration(
                  labelText: 'Token (private / DRM streams only)',
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _isLive,
                onChanged: (value) => setState(() => _isLive = value),
                title: const Text('Live stream'),
              ),

              const _SectionLabel('DRM'),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _drmEnabled,
                onChanged: (value) => setState(() => _drmEnabled = value),
                title: const Text('DRM protected'),
                subtitle: const Text(
                  'Leave off for ordinary streams. DRM media only.',
                ),
              ),
              if (_drmEnabled) ...[
                const SizedBox(height: 8),
                TextField(
                  controller: _drmToken,
                  decoration: const InputDecoration(labelText: 'DRM token'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _drmHost,
                  decoration: const InputDecoration(
                    labelText: 'DRM host',
                    // The licence is a second origin, and pointing it at the
                    // wrong environment fails at the handshake — which reads
                    // like a bad token, not a wrong host.
                    helperText: 'Blank uses api.fastpix.com. Match the stream '
                        'host environment.',
                  ),
                ),
              ],

              const _SectionLabel('External subtitles'),
              const Text(
                'Optional. Captions inside the HLS manifest are picked up '
                'automatically and do not need to be listed here.',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _subtitleUrl,
                decoration: const InputDecoration(labelText: 'WebVTT URL'),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _subtitleLabel,
                      decoration: const InputDecoration(labelText: 'Label'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 110,
                    child: TextField(
                      controller: _subtitleLanguage,
                      decoration: const InputDecoration(
                        labelText: 'Lang',
                        hintText: 'en',
                      ),
                    ),
                  ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _subtitlesOnByDefault,
                onChanged:
                    (value) => setState(() => _subtitlesOnByDefault = value),
                title: const Text('Start with subtitles on'),
              ),

              const SizedBox(height: 24),
              FilledButton(
                onPressed: _save,
                child: Text(isEditing ? 'Save changes' : 'Add to catalog'),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 12),
      child: Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w700,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}
