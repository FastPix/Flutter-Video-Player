import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FastPix Player Demo',
      theme: ThemeData.dark(useMaterial3: true),
      home: const FastPixPlayerDemo(),
    );
  }
}

class FastPixPlayerDemo extends StatefulWidget {
  const FastPixPlayerDemo({super.key});

  @override
  State<FastPixPlayerDemo> createState() => _FastPixPlayerDemoState();
}

class _FastPixPlayerDemoState extends State<FastPixPlayerDemo> {
  /// Paste a playback ID that has reached the "ready" status in the
  /// FastPix dashboard. A token is only needed for private/DRM streams.
  final _playbackIdController = TextEditingController();
  final _tokenController = TextEditingController();

  /// DRM protected media additionally needs a license token. When the JWT is
  /// generated with the "DRM License" feature enabled, the same value works for
  /// both fields.
  final _drmTokenController = TextEditingController();

  /// DRM is opt-in. A populated DRM token must not turn an ordinary playback ID
  /// into a DRM load: that routes clear media through Widevine/FairPlay and it
  /// never plays. Off by default so a plain playback ID plays plainly.
  bool _drmEnabled = false;

  FastPixPlayerController? _controller;
  String? _streamUrl;
  final _events = <String>[];

  void _log(String message) {
    if (!mounted) return;
    setState(() {
      _events.insert(0, message);
      if (_events.length > 50) _events.removeLast();
    });
  }

  Future<void> _load() async {
    final playbackId = _playbackIdController.text.trim();
    if (playbackId.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Enter a playback ID first')));
      return;
    }

    // Tear down any previous playback before starting a new one.
    await _controller?.dispose();
    final token = _tokenController.text.trim();
    final drmToken = _drmTokenController.text.trim();
    final dataSource = FastPixPlayerDataSource.hls(
      playbackId: playbackId,
      token: token.isEmpty ? null : token,
      // Only when DRM is explicitly switched on — a leftover token in the field
      // must not silently make an ordinary stream a DRM one.
      drmConfiguration:
          !_drmEnabled || drmToken.isEmpty
              ? null
              : FastPixPlayerDrmConfiguration(drmToken: drmToken),
      title: 'Sample HLS Stream',
      videoData: VideoDetailsData(videoId: playbackId, title: 'Sample HLS'),
    );

    // workSpaceId / viewerId / beaconUrl feed the FastPix metrics SDK.
    final configuration = FastPixPlayerConfiguration(
      'demo-workspace',
      'demo-viewer',
      'metrix.ws.fastpix.io',
      controlsConfiguration: const FastPixPlayerControlsConfiguration(
        autoPlay: true,
        enableRetry: true,
      ),
    );

    final controller = FastPixPlayerController();
    controller.addGlobalListener((event) {
      // DRM failures carry a code and an actionable message, everything else
      // is logged by type.
      if (event is FastPixPlayerDrmErrorEvent) {
        _log('${event.type} [${event.code}] ${event.message}');
      } else {
        _log(event.type);
      }
    });

    try {
      await controller.initialize(
        dataSource: dataSource,
        configuration: configuration,
      );
    } on FastPixDrmException catch (error) {
      // The controller already emitted the error event; surface it here too so
      // a bad DRM setup is visible instead of an endless spinner.
      if (!mounted) return;
      setState(() {
        _controller = controller;
        _streamUrl = null;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('DRM: ${error.message}')));
      return;
    }

    setState(() {
      _events.clear();
      _controller = controller;
      _streamUrl = dataSource.url;
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    _playbackIdController.dispose();
    _tokenController.dispose();
    _drmTokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      appBar: AppBar(title: const Text('FastPix Player Example')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _playbackIdController,
            decoration: const InputDecoration(
              labelText: 'Playback ID',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tokenController,
            decoration: const InputDecoration(
              labelText: 'Token (only for private / DRM streams)',
              border: OutlineInputBorder(),
            ),
          ),
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
            const SizedBox(height: 12),
            TextField(
              controller: _drmTokenController,
              decoration: const InputDecoration(
                labelText: 'DRM token',
                border: OutlineInputBorder(),
              ),
            ),
          ],
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.play_arrow),
            label: const Text('Load & play'),
          ),
          const SizedBox(height: 20),
          if (_streamUrl != null) ...[
            SelectableText(
              _streamUrl!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
          ],
          if (controller != null)
            FastPixPlayer(
              // No key needed: the player re-initializes itself when it is
              // given a different controller. Keying off the stream URL would
              // miss a changed DRM token, which does not appear in that URL.
              controller: controller,
              height: 220,
            )
          else
            Container(
              height: 220,
              color: Colors.black,
              alignment: Alignment.center,
              child: const Text('Enter a playback ID to start'),
            ),
          const SizedBox(height: 20),
          Text('Events', style: Theme.of(context).textTheme.titleMedium),
          const Divider(),
          for (final event in _events)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(event, style: const TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }
}
