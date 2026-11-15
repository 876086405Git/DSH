package io.github.ccch1mneyyy.dsh_app.nativemedia

import kotlin.math.log10
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Speech activity from the microphone's level, 20 ms frame by frame: an energy gate over an
 * adaptive noise floor, with hysteresis and a hangover.
 *
 * While the app plays a clip the gate is stricter — a higher margin over the floor learned before
 * the clip, a longer run of loud frames, and the first [SETTLE_MS] ignored while the echo canceller
 * adapts — so the clip's own echo is not taken for the person speaking. That only lowers the risk:
 * on a loud speaker without a working echo canceller the clip can still trip it (and stop itself),
 * and quiet speech over the clip can be missed. Nothing here keeps or sends audio.
 */
class SpeechGate(
    private val echoCancelled: Boolean = true,
    override var pause: TurnPause = TurnPause.NORMAL,
) : TurnGate {
    enum class Edge { NONE, START, END }

    private var floor = Double.NaN
    private var loud = 0
    private var quietMs = 0L
    private var speaking = false
    private var playingSince = -1L

    /** The app is playing a clip (or stopped playing one) at [nowMs]. */
    override fun setPlaying(on: Boolean, nowMs: Long) {
        playingSince = if (on) (if (playingSince >= 0) playingSince else nowMs) else -1L
        if (!on) loud = 0
    }

    val isSpeaking get() = speaking

    override fun consume(frame: ShortArray, levelDb: Double, nowMs: Long): Edge = consume(levelDb, nowMs)

    override fun reset() {
        loud = 0
        quietMs = 0
        speaking = false
    }

    /** One frame's level in dBFS at [nowMs]; the edge it makes, if any. */
    fun consume(levelDb: Double, nowMs: Long): Edge {
        val playing = playingSince >= 0
        if (floor.isNaN()) floor = levelDb.coerceAtMost(QUIET_FLOOR_DB)
        // The floor falls fast and rises slowly, never while someone speaks, and never with the
        // clip's echo (it would carry the threshold up with it).
        if (levelDb < floor) floor += (levelDb - floor) * 0.5
        else if (!speaking && !playing) floor += (levelDb - floor) * 0.01
        val start = max(floor + if (playing) playMargin() else MARGIN_DB, if (playing) PLAY_MIN_DB else MIN_DB)
        if (!speaking) {
            if (playing && nowMs - playingSince < SETTLE_MS) {
                loud = 0
                return Edge.NONE
            }
            loud = if (levelDb >= start) loud + 1 else 0
            if (loud >= if (playing) PLAY_START_FRAMES else START_FRAMES) {
                speaking = true
                loud = 0
                quietMs = 0
                return Edge.START
            }
            return Edge.NONE
        }
        // Speaking: over when it stays below the start threshold less the hysteresis.
        if (levelDb < start - HYSTERESIS_DB) {
            quietMs += FRAME_MS
            if (quietMs >= pause.hangoverMs) {
                speaking = false
                quietMs = 0
                return Edge.END
            }
        } else {
            quietMs = 0
        }
        return Edge.NONE
    }

    private fun playMargin() = if (echoCancelled) PLAY_MARGIN_DB else PLAY_MARGIN_NO_AEC_DB

    companion object {
        const val FRAME_MS = 20L
        const val MARGIN_DB = 15.0
        const val PLAY_MARGIN_DB = 24.0
        const val PLAY_MARGIN_NO_AEC_DB = 30.0
        const val MIN_DB = -50.0
        const val PLAY_MIN_DB = -40.0
        const val QUIET_FLOOR_DB = -60.0
        const val HYSTERESIS_DB = 6.0
        const val START_FRAMES = 6        // 120 ms
        const val PLAY_START_FRAMES = 10  // 200 ms
        const val SETTLE_MS = 400L

        /** RMS of PCM16 samples in dBFS (−100 for silence). */
        fun levelOf(samples: ShortArray, count: Int): Double {
            if (count <= 0) return -100.0
            var sum = 0.0
            for (i in 0 until count) {
                val s = samples[i].toDouble()
                sum += s * s
            }
            val rms = sqrt(sum / count) / 32768.0
            return if (rms <= 1e-5) -100.0 else 20 * log10(rms)
        }
    }
}
