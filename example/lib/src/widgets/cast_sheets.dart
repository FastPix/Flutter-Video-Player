import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';

import '../cast_service.dart';
import '../theme.dart';

/// Grab handle and title used by every sheet here.
class _SheetHeader extends StatelessWidget {
  const _SheetHeader({required this.title, this.subtitle, this.trailing});

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          subtitle!,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // A zero-size box rather than a conditional element: a
              // null-aware element needs a newer language version than this
              // package declares, and it renders identically.
              trailing ?? const SizedBox.shrink(),
            ],
          ),
        ],
      ),
    );
  }
}

/// Device picker, driven live so devices appearing mid-scan show up.
Future<FastPixCastDevice?> showCastDevicePicker(BuildContext context) {
  final cast = CastService.instance;

  return showModalBottomSheet<FastPixCastDevice>(
    context: context,
    builder: (sheetContext) {
      return SafeArea(
        child: ListenableBuilder(
          listenable: cast,
          builder: (context, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _SheetHeader(
                  title: 'Cast to',
                  subtitle: 'Devices on this Wi-Fi network',
                  trailing: IconButton(
                    tooltip: 'Rescan',
                    icon: const Icon(Icons.refresh),
                    onPressed: cast.rescan,
                  ),
                ),
                const Divider(),
                if (cast.devices.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(28),
                    child: Text(
                      'No devices found yet.',
                      style: TextStyle(color: AppColors.textSecondary),
                    ),
                  ),
                for (final device in cast.devices)
                  ListTile(
                    leading: const Icon(Icons.cast),
                    title: Text(device.name),
                    subtitle: Text(device.modelName ?? device.id),
                    onTap: () => Navigator.pop(sheetContext, device),
                  ),
                const SizedBox(height: 12),
              ],
            );
          },
        ),
      );
    },
  );
}

/// Subtitle picker for the receiver.
///
/// Lists what the receiver reports rather than what was sent to it, so
/// captions found inside the HLS manifest appear alongside external files.
Future<void> showCastSubtitleSheet(BuildContext context) {
  final cast = CastService.instance;

  return showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) {
      return SafeArea(
        child: ListenableBuilder(
          listenable: cast,
          builder: (context, _) => _SubtitleSheetBody(cast: cast),
        ),
      );
    },
  );
}

class _SubtitleSheetBody extends StatelessWidget {
  const _SubtitleSheetBody({required this.cast});

  final CastService cast;

  @override
  Widget build(BuildContext context) {
    final tracks = cast.textTracks;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const _SheetHeader(
          title: 'Subtitles',
          subtitle: 'Playing on the receiver',
        ),
        const Divider(),
        if (tracks.isEmpty)
          const Padding(
            padding: EdgeInsets.all(28),
            child: Text(
              'The receiver has not reported any subtitle tracks for '
              'this stream.',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          )
        else
          _TextTrackChoices(cast: cast, tracks: tracks),
        const SizedBox(height: 12),
      ],
    );
  }
}

class _TextTrackChoices extends StatelessWidget {
  const _TextTrackChoices({required this.cast, required this.tracks});

  final CastService cast;
  final List<FastPixCastTextTrack> tracks;

  @override
  Widget build(BuildContext context) {
    return RadioGroup<int?>(
      groupValue: cast.activeTextTrackId,
      onChanged: (int? id) {
        // A null id is the "Off" row, which selectTextTrack reads as
        // "turn subtitles off".
        final track = tracks.where((t) => t.id == id).firstOrNull;
        cast.controller.selectTextTrack(track);
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const RadioListTile<int?>(value: null, title: Text('Off')),
          for (final track in tracks) _TextTrackTile(track: track),
        ],
      ),
    );
  }
}

class _TextTrackTile extends StatelessWidget {
  const _TextTrackTile({required this.track});

  final FastPixCastTextTrack track;

  @override
  Widget build(BuildContext context) {
    final code = track.languageCode;
    return RadioListTile<int?>(
      value: track.id,
      title: Text(track.label),
      subtitle:
          code == null
              ? null
              : Text(track.isClosedCaption ? '$code \u00b7 CC' : code),
    );
  }
}

/// Cast diagnostics.
///
/// Discovery fails silently in several ways — denied local network
/// permission, guest Wi-Fi blocking mDNS, an unregistered receiver — so the
/// raw state is on screen rather than only a button that may never appear.
Future<void> showCastDiagnosticsSheet(BuildContext context) {
  final cast = CastService.instance;

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) {
      return SafeArea(
        child: ListenableBuilder(
          listenable: cast,
          builder: (context, _) {
            return DraggableScrollableSheet(
              initialChildSize: 0.7,
              minChildSize: 0.4,
              maxChildSize: 0.95,
              expand: false,
              builder:
                  (context, scrollController) => ListView(
                    controller: scrollController,
                    children: [
                      _SheetHeader(
                        title: 'Chromecast',
                        subtitle: 'State: ${cast.state.name}',
                        trailing: IconButton(
                          tooltip: 'Rescan',
                          icon: const Icon(Icons.refresh),
                          onPressed: cast.rescan,
                        ),
                      ),
                      SwitchListTile(
                        value: cast.useFmp4,
                        onChanged:
                            cast.state.hasSession
                                ? null
                                : cast.setSegmentFormat,
                        title: const Text('Stream uses fMP4 / CMAF segments'),
                        subtitle: const Text(
                          'Turn off if the receiver never starts playing.',
                        ),
                      ),
                      const Divider(),
                      _DeviceList(cast: cast),
                      _LastCastError(cast: cast),
                      const Divider(),
                      _EventLog(cast: cast),
                      const SizedBox(height: 24),
                    ],
                  ),
            );
          },
        ),
      );
    },
  );
}

class _DeviceList extends StatelessWidget {
  const _DeviceList({required this.cast});

  final CastService cast;

  @override
  Widget build(BuildContext context) {
    final connected = cast.connectedDevice;

    return Column(
      mainAxisSize: MainAxisSize.min,
      // These tiles were direct ListView children before being grouped here,
      // so they must keep receiving full-width constraints.
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          dense: true,
          title: const Text('Devices found'),
          trailing: Text('${cast.devices.length}'),
        ),
        if (connected != null)
          ListTile(
            dense: true,
            leading: const Icon(Icons.cast_connected, size: 20),
            title: Text(connected.name),
            subtitle: const Text('Connected'),
          ),
        for (final device in cast.devices)
          ListTile(
            dense: true,
            leading: const Icon(Icons.tv, size: 20),
            title: Text(device.name),
            subtitle: Text(device.modelName ?? 'unknown model'),
          ),
      ],
    );
  }
}

class _LastCastError extends StatelessWidget {
  const _LastCastError({required this.cast});

  final CastService cast;

  @override
  Widget build(BuildContext context) {
    final error = cast.lastError;
    if (error == null) return const SizedBox.shrink();

    // Android stops showing the permission dialog after a couple of refusals,
    // so re-requesting achieves nothing and Settings is the only way back.
    final needsSettings =
        error.errorCode == FastPixCastErrorCode.nearbyPermissionDenied;

    return Column(
      mainAxisSize: MainAxisSize.min,
      // Same reason as _DeviceList: these were direct ListView children.
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Text(
            error.message,
            style: const TextStyle(fontSize: 12, color: AppColors.accent),
          ),
        ),
        if (needsSettings)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TextButton.icon(
              onPressed: cast.controller.openPermissionSettings,
              icon: const Icon(Icons.settings, size: 16),
              label: const Text('Open app settings'),
            ),
          ),
      ],
    );
  }
}

class _EventLog extends StatelessWidget {
  const _EventLog({required this.cast});

  final CastService cast;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 4),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Events',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              TextButton(
                onPressed: cast.clearLog,
                child: const Text('Clear'),
              ),
            ],
          ),
        ),
        for (final event in cast.events)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 3),
            child: Text(
              event,
              style: const TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: AppColors.textSecondary,
              ),
            ),
          ),
      ],
    );
  }
}
