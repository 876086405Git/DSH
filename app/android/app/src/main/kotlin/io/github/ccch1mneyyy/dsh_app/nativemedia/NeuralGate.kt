package io.github.ccch1mneyyy.dsh_app.nativemedia

import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference

/** Silero opens a turn; smart-turn checks its tail without blocking microphone reads. */
class NeuralGate(
    private val vad: VadModel,
    private val turn: TurnModel,
    private val echoCancelled: Boolean = true,
    private val worker: ExecutorService = Executors.newSingleThreadExecutor { task ->
        Thread(task, "dsh-turn-model").apply { isDaemon = true }
    },
    /** The turn model failed on a pause (said once per gate): that pause ends the energy gate's way. */
    private val onTurnFailed: (Exception) -> Unit = {},
    override var pause: TurnPause = TurnPause.NORMAL,
) : TurnGate {
    interface VadModel : AutoCloseable {
        fun probability(frame: ShortArray): Float
        fun reset()
        override fun close()
    }

    interface TurnModel : AutoCloseable {
        /** Exactly eight seconds at 16 kHz, left padded with zero, normalized PCM16. */
        fun probability(audio: FloatArray): Float
        override fun close()
    }

    private data class Prediction(val generation: Long, val probability: Float, val failure: Exception? = null)

    private val audio = ShortArray(WINDOW_SAMPLES)
    private val snapshot = FloatArray(WINDOW_SAMPLES)
    private val completed = AtomicReference<Prediction?>()
    private var written = 0
    private var size = 0
    private var generation = 0L
    private var pending = false
    private var speaking = false
    private var loudSamples = 0
    private var quietSamples = 0
    private var requestedQuietSamples = 0
    private var utteranceSamples = 0
    private var playingSince = -1L

    /** This pause's check failed: it ends after the energy gate's hangover instead. */
    private var turnFailed = false

    /** The turn model's last word on this pause: done. Believed once the pause is [TurnPause.doneMs] long. */
    private var done = false
    private var reported = false

    override fun setPlaying(on: Boolean, nowMs: Long) {
        playingSince = if (on) (if (playingSince >= 0) playingSince else nowMs) else -1L
        if (!on) loudSamples = 0
    }

    override fun consume(frame: ShortArray, levelDb: Double, nowMs: Long): SpeechGate.Edge {
        append(frame)
        val probability = vad.probability(frame)
        val prediction = completed.getAndSet(null)
        if (prediction != null) pending = false
        val playing = playingSince >= 0
        val threshold = if (playing) (if (echoCancelled) PLAY_THRESHOLD else PLAY_NO_AEC_THRESHOLD) else THRESHOLD
        val voice = probability >= threshold
        if (!speaking) {
            if (playing && nowMs - playingSince < SpeechGate.SETTLE_MS) {
                loudSamples = 0
                return SpeechGate.Edge.NONE
            }
            loudSamples = if (voice) loudSamples + frame.size else 0
            if (loudSamples < if (playing) PLAY_START_SAMPLES else START_SAMPLES) return SpeechGate.Edge.NONE
            speaking = true
            generation++
            loudSamples = 0
            quietSamples = 0
            requestedQuietSamples = 0
            size = minOf(size, PREROLL_SAMPLES + frame.size)
            utteranceSamples = size
            return SpeechGate.Edge.START
        }

        utteranceSamples += frame.size
        if (voice) {
            if (quietSamples > 0) generation++
            quietSamples = 0
            requestedQuietSamples = 0
            turnFailed = false
            done = false
        } else {
            quietSamples += frame.size
        }
        if (utteranceSamples >= MAX_SAMPLES || quietSamples >= samples(pause.forceMs)) return end()
        if (prediction != null && prediction.generation == generation) {
            val failure = prediction.failure
            if (failure != null) {
                turnFailed = true
                done = false
                if (!reported) {
                    reported = true
                    onTurnFailed(failure)
                }
            } else {
                // A later check may take it back (a short pause looks finished more often than a long one).
                done = prediction.probability >= END_THRESHOLD
            }
        }
        // A short pause mid-sentence often looks finished: the model is believed
        // only once the pause is as long as the person asked for.
        if (done && quietSamples >= samples(pause.doneMs)) return end()
        if (turnFailed && quietSamples >= samples(pause.hangoverMs)) return end()
        if (!pending && quietSamples - requestedQuietSamples >= CHECK_SAMPLES) {
            snapshot.fill(0f, 0, WINDOW_SAMPLES - size)
            var source = (written - size + WINDOW_SAMPLES) % WINDOW_SAMPLES
            for (target in WINDOW_SAMPLES - size until WINDOW_SAMPLES) {
                snapshot[target] = audio[source] / 32768f
                if (++source == WINDOW_SAMPLES) source = 0
            }
            val mine = generation
            pending = true
            requestedQuietSamples = quietSamples
            worker.execute {
                val prediction = try {
                    Prediction(mine, turn.probability(snapshot))
                } catch (e: Exception) {
                    Prediction(mine, 0f, e)
                }
                completed.set(prediction)
            }
        }
        return SpeechGate.Edge.NONE
    }

    private fun samples(ms: Int) = RATE / 1000 * ms

    private fun append(frame: ShortArray) {
        var offset = 0
        while (offset < frame.size) {
            val count = minOf(frame.size - offset, WINDOW_SAMPLES - written)
            frame.copyInto(audio, written, offset, offset + count)
            written = (written + count) % WINDOW_SAMPLES
            offset += count
        }
        size = minOf(size + frame.size, WINDOW_SAMPLES)
    }

    private fun end(): SpeechGate.Edge {
        speaking = false
        turnFailed = false
        done = false
        generation++
        loudSamples = 0
        quietSamples = 0
        requestedQuietSamples = 0
        size = minOf(size, PREROLL_SAMPLES)
        return SpeechGate.Edge.END
    }

    override fun reset() {
        if (size == 0) return
        speaking = false
        turnFailed = false
        done = false
        generation++
        loudSamples = 0
        quietSamples = 0
        requestedQuietSamples = 0
        utteranceSamples = 0
        written = 0
        size = 0
        audio.fill(0)
        vad.reset()
    }

    override fun close() {
        vad.close()
        // After any inference still using the session.
        worker.execute { turn.close() }
        worker.shutdown()
    }

    companion object {
        const val RATE = 16000
        const val WINDOW_SAMPLES = RATE * 8
        const val THRESHOLD = 0.5f
        const val PLAY_THRESHOLD = 0.7f
        const val PLAY_NO_AEC_THRESHOLD = 0.85f
        private const val END_THRESHOLD = 0.5f
        private const val START_SAMPLES = RATE * 120 / 1000
        private const val PLAY_START_SAMPLES = RATE * 200 / 1000
        private const val CHECK_SAMPLES = RATE * 200 / 1000
        private const val PREROLL_SAMPLES = RATE * 300 / 1000
        private const val MAX_SAMPLES = RATE * 110
    }
}
