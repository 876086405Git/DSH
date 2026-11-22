package io.github.ccch1mneyyy.dsh_app.voice

/** One explicitly enabled tap; neither capture allocates event bytes while it is off. */
object StreamingPcm {
    class Tap(val source: String, val id: Long, val send: (Tap, ByteArray, () -> Boolean) -> Unit)
    @Volatile private var tap: Tap? = null

    fun enable(source: String, id: Long, send: (Tap, ByteArray, () -> Boolean) -> Unit) {
        tap = Tap(source, id, send)
    }

    fun disable(id: Long? = null) {
        if (id == null || tap?.id == id) tap = null
    }

    fun current(source: String): Tap? = tap?.takeIf { it.source == source }
    fun current(value: Tap): Boolean = tap === value

    fun offer(value: Tap, frame: ShortArray, valid: () -> Boolean) {
        if (!current(value)) return
        val bytes = ByteArray(frame.size * 2)
        for (i in frame.indices) {
            val sample = frame[i].toInt()
            bytes[i * 2] = sample.toByte()
            bytes[i * 2 + 1] = (sample shr 8).toByte()
        }
        value.send(value, bytes, valid)
    }
}

/** Rechunks recorder reads into 20 ms of PCM16 at 16 kHz, including 48/44.1 kHz devices. */
class PcmFrames(private val rate: Int) {
    private val input = ShortArray(rate / 50)
    private val output = ShortArray(320)
    private var filled = 0

    fun reset() { filled = 0 }

    fun consume(samples: ShortArray, count: Int, send: (ShortArray) -> Unit) {
        var offset = 0
        while (offset < count) {
            val take = minOf(count - offset, input.size - filled)
            samples.copyInto(input, filled, offset, offset + take)
            filled += take
            offset += take
            if (filled != input.size) continue
            if (rate == 16000) {
                input.copyInto(output)
            } else {
                for (i in output.indices) {
                    val first = i * rate / 16000
                    val end = (i + 1) * rate / 16000
                    var sum = 0
                    for (j in first until end) sum += input[j]
                    output[i] = (sum / (end - first)).toShort()
                }
            }
            send(output)
            filled = 0
        }
    }
}
