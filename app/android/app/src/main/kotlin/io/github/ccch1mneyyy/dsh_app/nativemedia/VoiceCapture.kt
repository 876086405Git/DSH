package io.github.ccch1mneyyy.dsh_app.nativemedia

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AudioEffect
import android.os.Handler
import android.os.SystemClock

/**
 * Listens for the person speaking while a plugin reads: 16 kHz mono from the voice-communication
 * source (the one Android applies echo cancellation to), with the platform's
 * [AcousticEchoCanceler] on when the device has one, through a [SpeechGate]. Frames are measured
 * and dropped on the capture thread; only the gate's edges reach the main thread.
 *
 * [stop] ends the capture before it returns (it waits briefly for the thread), so the microphone
 * is free for dictation right after.
 */
class VoiceCapture(
    private val main: Handler,
    private val onEdge: (SpeechGate.Edge) -> Unit,
    private val onError: (String) -> Unit,
) {
    private var record: AudioRecord? = null
    private var aec: AcousticEchoCanceler? = null
    private var thread: Thread? = null
    private var gate: SpeechGate? = null

    @Volatile private var running = false
    @Volatile private var playing = false
    private var session = 0

    /** The platform echo canceller is on for this capture. */
    var echoCancelled = false
        private set

    val active get() = record != null

    @SuppressLint("MissingPermission") // NativeMediaPlugin checks RECORD_AUDIO first.
    fun start(): Boolean {
        stop()
        val min = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (min <= 0) return false
        val r = runCatching {
            AudioRecord(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                maxOf(min, RATE / 5 * 2), // 200 ms
            )
        }.getOrNull() ?: return false
        if (r.state != AudioRecord.STATE_INITIALIZED) {
            r.release()
            return false
        }
        echoCancelled = false
        if (runCatching { AcousticEchoCanceler.isAvailable() }.getOrDefault(false)) {
            aec = runCatching { AcousticEchoCanceler.create(r.audioSessionId) }.getOrNull()?.also { effect ->
                echoCancelled = runCatching { effect.setEnabled(true) == AudioEffect.SUCCESS && effect.enabled }.getOrDefault(false)
            }
        }
        val started = runCatching { r.startRecording() }.isSuccess && r.recordingState == AudioRecord.RECORDSTATE_RECORDING
        if (!started) {
            runCatching { aec?.release() }
            aec = null
            r.release()
            return false
        }
        record = r
        // 快's 700 ms: what voice input always had (the call's pause is its own setting).
        val g = SpeechGate(echoCancelled, TurnPause.QUICK).also { gate = it }
        if (playing) g.setPlaying(true, SystemClock.elapsedRealtime())
        running = true
        val mine = ++session
        thread = Thread({ capture(r, g, mine) }, "dsh-plugin-voice").also { it.start() }
        return true
    }

    /** The owner's clip started or stopped playing: the gate is stricter while it plays. */
    fun setPlaying(on: Boolean) {
        playing = on
        val g = gate ?: return
        synchronized(g) { g.setPlaying(on, SystemClock.elapsedRealtime()) }
    }

    private fun capture(r: AudioRecord, g: SpeechGate, mine: Int) {
        val frame = ShortArray((RATE * SpeechGate.FRAME_MS / 1000).toInt())
        var filled = 0
        try {
            while (running) {
                val n = r.read(frame, filled, frame.size - filled)
                if (!running) break
                if (n < 0) {
                    post(mine) { onError("capture") }
                    break
                }
                filled += n
                if (filled < frame.size) continue
                filled = 0
                val level = SpeechGate.levelOf(frame, frame.size)
                val edge = synchronized(g) { g.consume(level, SystemClock.elapsedRealtime()) }
                if (edge != SpeechGate.Edge.NONE) post(mine) { onEdge(edge) }
            }
        } catch (_: RuntimeException) {
            post(mine) { onError("capture") }
        } finally {
            frame.fill(0)
        }
    }

    private fun post(mine: Int, block: () -> Unit) {
        main.post { if (mine == session && running) block() }
    }

    /** Ends the capture: the thread leaves its read, the recorder and effect are released. */
    fun stop(): Boolean {
        session++
        running = false
        val r = record ?: return true
        record = null
        gate = null
        runCatching { r.stop() }
        val t = thread
        thread = null
        runCatching { t?.join(JOIN_MS) }
        val ended = t?.isAlive != true
        runCatching { aec?.release() }
        aec = null
        runCatching { r.release() }
        return ended
    }

    private companion object {
        const val RATE = 16000
        const val JOIN_MS = 300L
    }
}
