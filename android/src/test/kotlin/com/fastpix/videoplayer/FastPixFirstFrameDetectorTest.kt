package com.fastpix.videoplayer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The first-frame detector reads two private fields of the pinned engine. A
 * better_player_plus upgrade that renames or retypes either fails here, not
 * silently on a device.
 */
class FastPixFirstFrameDetectorTest {
    private val detector = FastPixFirstFrameDetector.Companion

    @Test
    fun `the engine's player registry is reachable`() {
        val field = detector.field(
            FastPixFirstFrameDetector.PLUGIN_CLASS,
            FastPixFirstFrameDetector.PLAYERS_FIELD,
        )
        assertNotNull(field)
        assertEquals("android.util.LongSparseArray", field!!.type.name)
    }

    @Test
    fun `each engine player's ExoPlayer is reachable`() {
        val field = detector.field(
            FastPixFirstFrameDetector.PLAYER_CLASS,
            FastPixFirstFrameDetector.EXO_PLAYER_FIELD,
        )
        assertNotNull(field)
        assertEquals("androidx.media3.exoplayer.ExoPlayer", field!!.type.name)
    }

    @Test
    fun `a renamed field is reported as missing`() {
        assertNull(
            detector.field(FastPixFirstFrameDetector.PLAYER_CLASS, "exoPlayerRenamed"),
        )
    }
}
