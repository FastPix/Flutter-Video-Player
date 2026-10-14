package com.fastpix.videoplayer

import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.LongSparseArray
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import io.flutter.embedding.engine.FlutterEngine
import java.lang.reflect.Field

/**
 * Reports when a prerendered engine player has a frame ready, by textureId.
 *
 * The engine keeps its players in a private registry, `BetterPlayerPlugin
 * .videoPlayers`, and each player's `ExoPlayer` in a private field, so both are
 * reached by reflection. The engine is pinned to exactly 1.2.1 for that reason,
 * and `FastPixFirstFrameDetectorTest` reflects both fields against it. Any
 * failure here answers `unsupported`, and Dart skips the prerender with
 * `featureDisabled`, keeping the warm player.
 *
 * The listener is attached before the seek: ExoPlayer signals the first frame
 * again after a seek resets the renderer. A seek to the position the player is
 * already at resets nothing, so a warm player already showing its start frame
 * is reported at once instead (measured on a moto g71: it timed out before).
 */
internal class FastPixFirstFrameDetector(
    private val engine: () -> FlutterEngine?,
    private val send: (method: String, textureId: Long) -> Unit,
) {
    private val watches = mutableMapOf<Long, Pair<ExoPlayer, Player.Listener>>()
    private val mainHandler = Handler(Looper.getMainLooper())

    /** Whether the engine's registry and player field can be reached. */
    fun isSupported(): Boolean = playersField != null && exoPlayerField != null

    /**
     * Seek [textureId]'s player to [positionMs] and report `frameReady` once the
     * frame there is rendered. False when the player cannot be reached.
     */
    fun watch(textureId: Long, positionMs: Long): Boolean {
        val player = exoPlayerFor(textureId) ?: return false
        stop(textureId)
        if (showsFrameAt(player, positionMs)) {
            // Posted so the answer to this call reaches Dart first.
            mainHandler.post { send("frameReady", textureId) }
            return true
        }
        val listener = object : Player.Listener {
            override fun onRenderedFirstFrame() {
                stop(textureId)
                send("frameReady", textureId)
            }
        }
        player.addListener(listener)
        watches[textureId] = player to listener
        try {
            player.seekTo(positionMs)
        } catch (error: RuntimeException) {
            Log.w(TAG, "seek for prerender $textureId failed", error)
            stop(textureId)
            send("seekFailed", textureId)
        }
        return true
    }

    /** Stop watching [textureId]. Harmless when nothing is watched. */
    fun stop(textureId: Long) {
        val (player, listener) = watches.remove(textureId) ?: return
        player.removeListener(listener)
    }

    fun stopAll() {
        for (textureId in watches.keys.toList()) stop(textureId)
    }

    /**
     * Whether [player] already shows its frame at [positionMs].
     *
     * A warm player has rendered its start frame before it is lent, and
     * ExoPlayer skips a seek to the millisecond it is already at — no renderer
     * reset, so no second `onRenderedFirstFrame`. Its video renderer only
     * reports ready once a frame is on the surface, so ready at the target
     * with a video size is that frame.
     */
    private fun showsFrameAt(player: ExoPlayer, positionMs: Long): Boolean =
        player.playbackState == Player.STATE_READY &&
            player.currentPosition == positionMs &&
            player.videoSize.width > 0

    private fun exoPlayerFor(textureId: Long): ExoPlayer? {
        val players = playersField ?: return null
        val field = exoPlayerField ?: return null
        return try {
            val plugin = engine()?.plugins?.get(pluginClass ?: return null) ?: return null
            val registry = players.get(plugin) as? LongSparseArray<*> ?: return null
            val player = registry.get(textureId) ?: return null
            field.get(player) as? ExoPlayer
        } catch (error: ReflectiveOperationException) {
            Log.w(TAG, "the engine player $textureId could not be reached", error)
            null
        } catch (error: ClassCastException) {
            Log.w(TAG, "the engine player $textureId has an unexpected shape", error)
            null
        }
    }

    internal companion object {
        private const val TAG = "FastPixFirstFrame"
        const val PLUGIN_CLASS = "uz.shs.better_player_plus.BetterPlayerPlugin"
        const val PLAYER_CLASS = "uz.shs.better_player_plus.BetterPlayer"
        const val PLAYERS_FIELD = "videoPlayers"
        const val EXO_PLAYER_FIELD = "exoPlayer"

        @Suppress("UNCHECKED_CAST")
        private val pluginClass: Class<out io.flutter.embedding.engine.plugins.FlutterPlugin>? =
            loadClass(PLUGIN_CLASS) as Class<out io.flutter.embedding.engine.plugins.FlutterPlugin>?

        private val playersField: Field? = field(PLUGIN_CLASS, PLAYERS_FIELD)
        private val exoPlayerField: Field? = field(PLAYER_CLASS, EXO_PLAYER_FIELD)

        private fun loadClass(name: String): Class<*>? = try {
            Class.forName(name)
        } catch (error: ReflectiveOperationException) {
            Log.w(TAG, "$name is not on this build", error)
            null
        } catch (error: LinkageError) {
            Log.w(TAG, "$name could not be loaded", error)
            null
        }

        /** [className]'s private [name] field, made readable, or null. */
        fun field(className: String, name: String): Field? = try {
            loadClass(className)?.getDeclaredField(name)?.apply { isAccessible = true }
        } catch (error: ReflectiveOperationException) {
            Log.w(TAG, "$className.$name is not on this build", error)
            null
        } catch (error: SecurityException) {
            Log.w(TAG, "$className.$name is not readable", error)
            null
        }
    }
}
