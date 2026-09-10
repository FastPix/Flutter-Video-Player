#
# Native iOS side of fastpix_video_player.
#
# Only the preload warmer lives here. Playback itself is better_player_plus's
# pod; this one sits beside it and does not depend on it, so nothing here can
# affect how a stream plays.
#
Pod::Spec.new do |s|
  s.name             = 'fastpix_video_player'
  s.version          = '1.1.2'
  s.summary          = 'FastPix video player preload support for iOS.'
  s.description      = <<-DESC
Warms AVURLAssets for upcoming titles so a tap does not pay for DNS, TLS and
the HLS playlist fetches.
                       DESC
  s.homepage         = 'https://github.com/FastPix/Flutter-Video-Player'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'FastPix' => 'aitools.player@fastpix.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  # Required so the Objective-C hooks are visible to this pod's Swift files.
  # Without it they are not in the umbrella header and Swift cannot see them.
  s.public_header_files = 'Classes/**/*.h'
  s.dependency 'Flutter'

  # 12.0 rather than 11.0: `preferredForwardBufferDuration` and the memory
  # pressure notification used by the warmer are both available earlier, but
  # 12.0 is what Flutter itself now requires, so a lower floor buys nothing.
  s.platform = :ios, '12.0'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
  s.swift_version = '5.0'
end
