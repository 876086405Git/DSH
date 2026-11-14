package io.github.ccch1mneyyy.dsh_app.speech

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.AudioEffect
import android.media.audiofx.NoiseSuppressor
import android.os.Handler
import android.os.SystemClock
import io.github.ccch1mneyyy.dsh_app.voice.StreamingPcm
import io.github.ccch1mneyyy.dsh_app.nativemedia.SpeechGate
import io.github.ccch1mneyyy.dsh_app.nativemedia.TurnGate
import io.github.ccch1mneyyy.dsh_app.nativemedia.TurnPause
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * The microphone during a voice call: 16 kHz mono from the voice-communication source with the
 * platform's echo canceller and noise suppressor when the phone has them, cut into utterances by a
 * [SpeechGate]. Each utterance (with the 300 ms before speech was detected, so the first syllable is
 * kept) is handed over as a WAV once the person pauses; nothing else is kept, and nothing at all is
 * recorded while muted.
 *
 * While the app's own voice plays ([setPlaying]) the gate is stricter. With [bargeIn] the person
 * speaking over it starts an utterance (the owner stops the playback); without it, speech during
 * playback is ignored.
 */
class CallCapture(
    private val main: Handler,
    private val listener: Listener,
    private val createGate: (Boolean) -> TurnGate = { SpeechGate(it) },
) {
    interface Listener {
        fun onSpeechStart(overPlayback: Boolean)
        fun onUtterance(wav: ByteArray, ms: Int)
        fun onLevel(value: Double)
        fun onError(reason: String)
    }

    private var record: AudioRecord? = null
    private var effects = mutableListOf<AudioEffect>()
    private var thread: Thread? = null
    private var gate: TurnGate? = null

    @Volatile private var running = false
    @Volatile private var playing = false
    @Volatile private var pcmEpoch = 0
    @Volatile var muted = false
        set(value) {
            if (field != value) pcmEpoch++
            field = value
        }
    @Volatile var bargeIn = true

    /** How long a pause ends what the person says; a change applies from the next frame. */
    @Volatile var pause = TurnPause.NORMAL
        set(value) {
            field = value
            val g = gate ?: return
            synchronized(g) { g.pause = value }
        }
    private var session = 0

    /** The platform echo canceller is on for this capture. */
    var echoCancelled = false
        private set

    val active get() = record != null

    @SuppressLint("MissingPermission") // SpeechPlugin checks RECORD_AUDIO first.
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
                maxOf(min, RATE / 5 * 2),
            )
        }.getOrNull() ?: return false
        if (r.state != AudioRecord.STATE_INITIALIZED) {
            r.release()
            return false
        }
        echoCancelled = false
        if (runCatching { AcousticEchoCanceler.isAvailable() }.getOrDefault(false)) {
            runCatching { AcousticEchoCanceler.create(r.audioSessionId) }.getOrNull()?.let { effect ->
                effects += effect
                echoCancelled = runCatching { effect.setEnabled(true) == AudioEffect.SUCCESS && effect.enabled }.getOrDefault(false)
            }
        }
        if (runCatching { NoiseSuppressor.isAvailable() }.getOrDefault(false)) {
            runCatching { NoiseSuppressor.create(r.audioSessionId) }.getOrNull()?.let { effect ->
                effects += effect
                runCatching { effect.setEnabled(true) }
            }
        }
        val g = createGate(echoCancelled).also { it.pause = pause }
        val started = runCatching { r.startRecording() }.isSuccess && r.recordingState == AudioRecord.RECORDSTATE_RECORDING
        if (!started) {
            g.close()
            releaseEffects()
            r.release()
            return false
        }
        record = r
        gate = g
        if (playing) g.setPlaying(true, SystemClock.elapsedRealtime())
        running = true
        val mine = ++session
        thread = Thread({ capture(r, g, mine) }, "dsh-speech-call").also { it.start() }
        return true
    }

    /** The app's own voice started or stopped playing. */
    fun setPlaying(on: Boolean) {
        playing = on
        val g = gate ?: return
        synchronized(g) { g.setPlaying(on, SystemClock.elapsedRealtime()) }
    }

    private fun capture(r: AudioRecord, g: TurnGate, mine: Int) {
        val frame = ShortArray((RATE * SpeechGate.FRAME_MS / 1000).toInt())
        val preroll = ArrayDeque<ShortArray>()
        var utterance: ByteArrayOutputStream? = null
        var utteranceFrames = 0
        var filled = 0
        var pcmTap: StreamingPcm.Tap? = null
        var frameEpoch = 0
        var tick = 0
        try {
            while (running) {
                if (filled == 0) {
                    pcmTap = StreamingPcm.current("call")
                    frameEpoch = pcmEpoch
                }
                val n = r.read(frame, filled, frame.size - filled)
                if (!running) break
                if (n < 0) {
                    post(mine) { listener.onError("capture") }
                    break
                }
                filled += n
                if (filled < frame.size) continue
                filled = 0
                if (muted) {
                    // Nothing heard, nothing kept: an utterance under way is dropped.
                    synchronized(g) { g.reset() }
                    utterance = null
                    preroll.clear()
                    frame.fill(0)
                    if (++tick % 2 == 0) post(mine) { listener.onLevel(0.0) }
                    continue
                }
                val level = SpeechGate.levelOf(frame, frame.size)
                pcmTap?.let { tap ->
                    val epoch = frameEpoch
                    StreamingPcm.offer(tap, frame) { running && mine == session && !muted && epoch == pcmEpoch }
                }
                if (++tick % 2 == 0) {
                    val shown = ((level + 60.0) / 50.0).coerceIn(0.0, 1.0)
                    post(mine) { listener.onLevel(shown) }
                }
                val overPlayback = playing
                val edge = synchronized(g) { g.consume(frame, level, SystemClock.elapsedRealtime()) }
                val current = utterance
                when {
                    edge == SpeechGate.Edge.START && (!overPlayback || bargeIn) -> {
                        val out = ByteArrayOutputStream(RATE * 2 * 4)
                        for (old in preroll) append(out, old)
                        append(out, frame)
                        utterance = out
                        utteranceFrames = preroll.size + 1
                        post(mine) { listener.onSpeechStart(overPlayback) }
                    }
                    current != null -> {
                        append(current, frame)
                        utteranceFrames++
                        if (edge == SpeechGate.Edge.END || utteranceFrames * SpeechGate.FRAME_MS >= MAX_MS) {
                            if (edge != SpeechGate.Edge.END) synchronized(g) { g.reset() }
                            utterance = null
                            val ms = (utteranceFrames * SpeechGate.FRAME_MS).toInt()
                            val wav = wav(current.toByteArray())
                            post(mine) { listener.onUtterance(wav, ms) }
                        }
                    }
                }
                preroll.addLast(frame.copyOf())
                while (preroll.size > PREROLL_FRAMES) preroll.removeFirst()
            }
        } catch (_: Exception) {
            post(mine) { listener.onError("capture") }
        } finally {
            synchronized(g) { g.close() }
            frame.fill(0)
            preroll.clear()
        }
    }

    private fun append(out: ByteArrayOutputStream, samples: ShortArray) {
        val buffer = ByteBuffer.allocate(samples.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        for (s in samples) buffer.putShort(s)
        out.write(buffer.array())
    }

    private fun post(mine: Int, block: () -> Unit) {
        main.post { if (mine == session && running) block() }
    }

    /** Ends the capture: the thread leaves its read, the recorder and effects are released. */
    fun stop() {
        session++
        running = false
        val r = record ?: return
        record = null
        gate = null
        runCatching { r.stop() }
        val t = thread
        thread = null
        runCatching { t?.join(JOIN_MS) }
        releaseEffects()
        runCatching { r.release() }
    }

    private fun releaseEffects() {
        for (effect in effects) runCatching { effect.release() }
        effects = mutableListOf()
    }

    companion object {
        const val RATE = 16000
        const val JOIN_MS = 300L
        const val PREROLL_FRAMES = 15 // 300 ms
        // DeepSeek's recognizer takes at most 120 s; an utterance is cut well before.
        const val MAX_MS = 110_000L

        fun wav(pcm: ByteArray): ByteArray {
            val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
            header.put("RIFF".toByteArray()).putInt(36 + pcm.size).put("WAVE".toByteArray())
            header.put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(1).putInt(RATE).putInt(RATE * 2)
                .putShort(2).putShort(16)
            header.put("data".toByteArray()).putInt(pcm.size)
            return header.array() + pcm
        }
    }
}
