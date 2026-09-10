library;

export 'src/fastpix_player_widget.dart';
export 'src/fastpix_player_controller.dart';
export 'src/fastpix_player_configuration.dart';
export 'src/models/fastpix_player_data_source.dart';
export 'src/models/fastpix_player_subtitle.dart';
export 'src/models/fastpix_player_drm_configuration.dart';
export 'src/models/fastpix_player_drm_error.dart';
export 'src/models/fastpix_player_controls_configuration.dart';
export 'src/models/fastpix_player_quality_configuration.dart';
export 'src/utils/fastpix_player_utils.dart';
export 'src/utils/fastpix_playback_diagnostics.dart';
export 'src/models/video_details_data.dart';
export 'src/enums/fastpix_player_video_quality.dart';
export 'src/enums/fastpix_player_rendition_order.dart';
export 'src/enums/fastpix_player_state.dart';
export 'src/enums/fastpix_controls_visibility.dart';

// Chromecast exports
export 'src/fastpix_cast_button.dart';
export 'src/fastpix_cast_controller.dart';
export 'src/enums/fastpix_cast_state.dart';
export 'src/enums/fastpix_cast_segment_format.dart';
export 'src/models/fastpix_cast_device.dart';
export 'src/models/fastpix_cast_error.dart';
export 'src/models/fastpix_cast_event.dart';
export 'src/models/fastpix_cast_text_track.dart';

// Preload exports
export 'src/fastpix_preload_manager.dart';
export 'src/enums/fastpix_preload_strategy.dart';
export 'src/enums/fastpix_preload_status.dart';
export 'src/enums/fastpix_network_type.dart';
export 'src/utils/fastpix_network_monitor.dart';
export 'src/models/fastpix_preload_event.dart';
export 'src/utils/fastpix_manifest_warmer.dart';
export 'src/utils/fastpix_better_player_configuration.dart';
export 'src/utils/fastpix_host_warmer.dart';
export 'src/utils/fastpix_playstart_trace.dart';
export 'src/utils/fastpix_warm_log.dart';
export 'src/utils/fastpix_drm_log.dart';
export 'src/utils/fastpix_user_leave_hint.dart';

// Precache exports
export 'src/fastpix_precache_manager.dart';
export 'src/enums/fastpix_precache_status.dart';
export 'src/models/fastpix_precache_event.dart';

// Playlist exports
export 'src/managers/fastpix_playlist_manager.dart';
export 'src/managers/fastpix_skip_manager.dart';
export 'src/models/fastpix_playlist_state.dart';
export 'src/models/fastpix_playlist_exception.dart';
export 'src/models/fastpix_skip_segment.dart';
export 'src/models/fastpix_playlist_event.dart';
export 'src/enums/fastpix_playlist_repeat_mode.dart';
export 'src/enums/fastpix_playlist_item_change_reason.dart';
export 'src/enums/fastpix_skip_type.dart';
export 'src/enums/fastpix_skip_failure_reason.dart';

// Event listener exports
export 'src/models/fastpix_player_event.dart';
export 'src/models/fastpix_player_event_types.dart';

// Custom UI mechanism exports (additive — headless surface + functionality API)
export 'src/widgets/fastpix_video_surface.dart';
// `FastPixPipBuilder` and the default layout, so a host can supply its own
// Picture-in-Picture window content.
export 'src/widgets/fastpix_pip_layout.dart';
export 'src/widgets/fastpix_playlist_panel.dart';
export 'src/models/fastpix_playback_state.dart';
export 'src/models/fastpix_quality_level.dart';
export 'src/models/fastpix_audio_track.dart';
export 'src/models/fastpix_subtitle_track.dart';
export 'src/models/fastpix_custom_ui_event.dart';
export 'src/enums/fastpix_custom_ui_error_code.dart';
export 'src/managers/fastpix_engine_accessor.dart';
export 'src/managers/fastpix_playback_rate_manager.dart';
export 'src/managers/fastpix_scrub_controller.dart';
export 'src/managers/fastpix_quality_manager.dart';
export 'src/managers/fastpix_audio_track_manager.dart';
export 'src/managers/fastpix_subtitle_track_manager.dart';
export 'src/managers/fastpix_pip_manager.dart';
