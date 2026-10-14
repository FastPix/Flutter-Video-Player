import 'package:flutter/material.dart';

import '../models/demo_stream.dart';
import '../theme.dart';

/// A video tile in a home-screen rail: a 16:9 gradient tile with the title
/// and badge line beneath it, as on YouTube.
class PosterCard extends StatelessWidget {
  const PosterCard({
    super.key,
    required this.stream,
    required this.gradientIndex,
    required this.onTap,
    this.onLongPress,
    this.width = 240,
  });

  final DemoStream stream;
  final int gradientIndex;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final double width;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.posterGradient(gradientIndex);
    final radius = BorderRadius.circular(12);

    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: ClipRRect(
              borderRadius: radius,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: colors,
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                  ),
                  if (stream.isLive)
                    const Positioned(top: 8, left: 8, child: _LiveBadge()),
                  if (stream.drmEnabled)
                    const Positioned(
                      top: 8,
                      right: 8,
                      child: Icon(
                        Icons.lock,
                        size: 14,
                        color: Colors.white,
                        shadows: <Shadow>[
                          Shadow(blurRadius: 6, color: Colors.black54),
                        ],
                      ),
                    ),
                  // On top, so the ripple shows over the image.
                  Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      onTap: onTap,
                      onLongPress: onLongPress,
                      borderRadius: radius,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            stream.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 13,
              height: 1.25,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            stream.badgeLine,
            style: const TextStyle(
              fontSize: 11,
              letterSpacing: 0.4,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.accent,
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        'LIVE',
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

/// A titled horizontal row of poster cards.
class PosterRail extends StatelessWidget {
  const PosterRail({
    super.key,
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 12),
          child: Text(
            title,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
        ),
        SizedBox(
          // A 240-wide 16:9 thumbnail, two lines of title and the badge line.
          height: 204,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: children.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (_, index) => children[index],
          ),
        ),
      ],
    );
  }
}
