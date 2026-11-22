package io.github.ccch1mneyyy.dsh_app.voice

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import io.github.ccch1mneyyy.dsh_app.speech.CallCapture
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Records the microphone as the engine's speech Remote wants it: one canonical 16 kHz mono PCM16 WAV
 * (`dsh-experimental-speech-to-text/wave`: 44-byte header, nothing else).
 *
 * Captures at 16 kHz when the device offers it, otherwise at 48 / 44.1 kHz and resamples on [finish].
 * Reports the input level about every 60 ms and stops capturing by itself after [maxSeconds].
 */
class WavRecorder(
    private val maxSeconds: Int,
    private val onLevel: (Double) -> Unit,
    private val onLimit: () -> Unit,
    private val onError: () -> Unit,
    private val isCurrentCapture: () -> Boolean = { true },
) {
    private var record: AudioRecord? = null
    private var thread: Thread? = null
    private var rate = TARGET_RATE
    private val pcm = ByteArrayOutputStream()
    private val captureState = Any()

    @Volatile
    private var running = false
    private var captureError: IOException? = null

    /** The capture's audio session (AudioManager's recording configurations name it); 0 when not recording. */
    val sessionId: Int get() = record?.audioSessionId ?: 0

    /** Opens the microphone and starts capturing; false when it cannot be opened. */
    @SuppressLint("MissingPermission") // VoicePlugin checks RECORD_AUDIO first.
    fun start(): Boolean {
        // Some devices refuse the recognition source; the plain mic then.
        val sources = intArrayOf(MediaRecorder.AudioSource.VOICE_RECOGNITION, MediaRecorder.AudioSource.MIC)
        for (source in sources) for (candidate in intArrayOf(TARGET_RATE, 48000, 44100)) {
            val min = AudioRecord.getMinBufferSize(candidate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
            if (min <= 0) continue
            val r = runCatching {
                AudioRecord(
                    source,
                    candidate,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                    max(min, candidate / 5 * 2), // at least 200 ms
                )
            }.getOrNull() ?: continue
            if (r.state != AudioRecord.STATE_INITIALIZED) {
                r.release()
                continue
            }
            val started = runCatching { r.startRecording() }.isSuccess &&
                r.recordingState == AudioRecord.RECORDSTATE_RECORDING
            if (!started) {
                r.release()
                continue
            }
            record = r
            rate = candidate
            synchronized(captureState) { running = true }
            thread = Thread({ capture() }, "dsh-voice-recorder").also { it.start() }
            return true
        }
        return false
    }

    private fun capture() {
        val r = record ?: return
        val chunk = ShortArray(rate * 60 / 1000) // ~60 ms
        val bytes = ByteBuffer.allocate(chunk.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        val limit = maxSeconds.toLong() * rate
        val frames = PcmFrames(rate)
        var pcmTap: StreamingPcm.Tap? = null
        var captured = 0L
        while (running) {
            val tap = StreamingPcm.current("dictation")
            val n = try {
                r.read(chunk, 0, chunk.size)
            } catch (error: RuntimeException) {
                failCapture(IOException("Could not read microphone", error))
                break
            }
            if (!running) break
            if (n < 0) {
                failCapture(IOException("Could not read microphone ($n)"))
                break
            }
            if (n == 0) continue
            val take = minOf(n.toLong(), limit - captured).toInt()
            bytes.clear()
            var sum = 0.0
            for (i in 0 until take) {
                val s = chunk[i]
                bytes.putShort(s)
                sum += s.toDouble() * s
            }
            synchronized(pcm) { pcm.write(bytes.array(), 0, take * 2) }
            if (tap !== pcmTap) {
                frames.reset()
                pcmTap = tap
            }
            if (tap != null) frames.consume(chunk, take) { StreamingPcm.offer(tap, it, isCurrentCapture) }
            captured += take
            onLevel(levelOf(sum, take))
            if (captured >= limit) {
                val reached = synchronized(captureState) {
                    if (!running) false else {
                        running = false
                        true
                    }
                }
                if (reached) onLimit()
                break
            }
        }
    }

    private fun failCapture(error: IOException) {
        // stopCapture retires the read before calling AudioRecord.stop(). Its
        // interrupted read must not turn an ordinary stop into a capture error.
        synchronized(captureState) {
            if (!running) return
            captureError = error
            running = false
        }
        onError()
    }

    /** RMS in dBFS mapped from -50..-10 dB to 0..1. */
    private fun levelOf(sumOfSquares: Double, count: Int): Double {
        if (count <= 0) return 0.0
        val rms = sqrt(sumOfSquares / count) / 32768.0
        if (rms <= 0.0) return 0.0
        val db = 20 * log10(rms)
        return ((db + 50) / 40).coerceIn(0.0, 1.0)
    }

    /** Stops capturing and returns the WAV, or null when nothing was captured.
     * A failed or still-running capture cannot be returned as a finished recording. */
    fun finish(): ByteArray? {
        if (!stopCapture()) throw IOException("Microphone capture did not stop")
        synchronized(captureState) { captureError }?.let { throw it }
        val raw = synchronized(pcm) { pcm.toByteArray() }
        if (raw.size < 2) return null
        if (rate == TARGET_RATE) return CallCapture.wav(raw)
        val samples = ShortArray(raw.size / 2)
        ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN).asShortBuffer().get(samples)
        return wav(resample(samples, rate, TARGET_RATE))
    }

    /** Stops capturing and drops the audio. */
    fun discard() {
        stopCapture()
        synchronized(pcm) { pcm.reset() }
    }

    private fun stopCapture(): Boolean {
        synchronized(captureState) { running = false }
        val r = record
        record = null
        runCatching { r?.stop() }
        val t = thread
        runCatching { t?.join(1000) }
        thread = null
        runCatching { r?.release() }
        return t?.isAlive != true
    }

    private fun resample(input: ShortArray, from: Int, to: Int): ShortArray {
        val outLength = (input.size.toLong() * to / from).toInt()
        val out = ShortArray(outLength)
        val step = from.toDouble() / to
        // Averages the source span of each output sample: a cheap low-pass before decimating.
        for (i in 0 until outLength) {
            val start = (i * step).toInt()
            val end = minOf(input.size, max(start + 1, ((i + 1) * step).toInt()))
            var sum = 0L
            for (j in start until end) sum += input[j]
            out[i] = (sum / (end - start)).toInt().toShort()
        }
        return out
    }

    private fun wav(samples: ShortArray): ByteArray {
        val dataLength = samples.size * 2
        val buffer = ByteBuffer.allocate(44 + dataLength).order(ByteOrder.LITTLE_ENDIAN)
        buffer.put("RIFF".toByteArray(Charsets.US_ASCII))
        buffer.putInt(36 + dataLength)
        buffer.put("WAVE".toByteArray(Charsets.US_ASCII))
        buffer.put("fmt ".toByteArray(Charsets.US_ASCII))
        buffer.putInt(16) // PCM fmt chunk size
        buffer.putShort(1.toShort()) // PCM
        buffer.putShort(1.toShort()) // mono
        buffer.putInt(TARGET_RATE)
        buffer.putInt(TARGET_RATE * 2) // byte rate
        buffer.putShort(2.toShort()) // block align
        buffer.putShort(16.toShort()) // bits per sample
        buffer.put("data".toByteArray(Charsets.US_ASCII))
        buffer.putInt(dataLength)
        for (s in samples) buffer.putShort(s)
        return buffer.array()
    }

    private companion object {
        const val TARGET_RATE = 16000
    }
}
