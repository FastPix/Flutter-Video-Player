import 'package:fastpix_video_player/fastpix_video_player.dart';
import 'package:flutter/material.dart';

import 'src/catalog.dart';
import 'src/home_screen.dart';
import 'src/theme.dart';

void main() async {
  // Restore the saved catalog before the first frame, so a relaunch replays
  // the SAME source — token included. Re-entering a stream by hand risks a
  // different token, a different URL, and therefore a different cache key,
  // which reads as "precaching does not work" when the test is at fault.
  WidgetsFlutterBinding.ensureInitialized();
  await Catalog.instance.load();

  // Layer B: one throwaway request per playback host. Both are expected to
  // fail — there is no token — but the DNS resolution and the warmed CDN edge
  // survive, and the native players share the OS DNS cache even though they
  // use their own HTTP stacks. Never awaited; it must not delay app start.
  // Hosts come from the catalog, not the SDK defaults, so a stream on a custom
  // domain is warmed at the domain it is actually played from.
  warmPlaybackHostsFor(
    Catalog.instance.streams.map((stream) => stream.toDataSource()),
  );

  // Prints the PLAYSTART trace. Filter with:
  //   flutter run --release | grep PLAYSTART
  FastPixPlayStartTrace.enabled = true;

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FastPix Player Demo',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const HomeScreen(),
    );
  }
}
