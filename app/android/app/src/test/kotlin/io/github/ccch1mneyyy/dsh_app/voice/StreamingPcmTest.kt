package io.github.ccch1mneyyy.dsh_app.voice

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StreamingPcmTest {
    @Test fun disabledAndStaleTapsDoNotEmitAndSourcesStaySeparate() {
        val sent = mutableListOf<ByteArray>()
        val frame = ShortArray(320) { -32767 }
        StreamingPcm.disable()
        assertEquals(null, StreamingPcm.current("call"))
        StreamingPcm.enable("call", 1) { _, bytes, valid -> if (valid()) sent += bytes }
        val stale = StreamingPcm.current("call")!!
        assertEquals(null, StreamingPcm.current("dictation"))
        assertTrue(sent.isEmpty())
        StreamingPcm.offer(stale, frame) { true }
        assertEquals(640, sent.single().size)
        assertEquals(1.toByte(), sent.single()[0])
        assertEquals(128.toByte(), sent.single()[1])
        StreamingPcm.enable("dictation", 2) { _, bytes, valid -> if (valid()) sent += bytes }
        StreamingPcm.disable(1)
        assertTrue(StreamingPcm.current("dictation") != null)
        assertFalse(StreamingPcm.current(stale))
        StreamingPcm.offer(stale, frame) { true }
        assertEquals(1, sent.size)
        StreamingPcm.disable()
    }

    @Test fun retirementAlsoDropsFramesAlreadyQueuedForTheMainThread() {
        val queued = mutableListOf<() -> Unit>()
        var delivered = 0
        var captureEpoch = 1
        StreamingPcm.enable("call", 3) { tap, _, valid ->
            queued += { if (StreamingPcm.current(tap) && valid()) delivered++ }
        }
        val tap = StreamingPcm.current("call")!!
        val beforeMute = captureEpoch
        StreamingPcm.offer(tap, ShortArray(320)) { captureEpoch == beforeMute }
        captureEpoch += 2 // mute and unmute before the main thread drains its queue
        queued.removeAt(0)()
        assertEquals(0, delivered)
        val newCapture = captureEpoch
        StreamingPcm.offer(tap, ShortArray(320)) { captureEpoch == newCapture }
        queued.removeAt(0)()
        assertEquals(1, delivered)
        StreamingPcm.disable()
    }

    @Test fun aPartialNextReadLeavesTheLastNativeRateFrameIntact() {
        val converter = PcmFrames(16000)
        val samples = ShortArray(320) { (Short.MIN_VALUE + it * 211).toShort() }
        samples[319] = Short.MAX_VALUE
        lateinit var emitted: ShortArray
        converter.consume(samples, samples.size) { emitted = it }
        assertArrayEquals(samples, emitted)
        converter.consume(shortArrayOf(1, 2), 2) { error("partial frame emitted") }
        assertArrayEquals(samples, emitted)
    }

    @Test fun arbitraryReadSizesYieldExactTwentyMillisecondFramesAtAllRecorderRates() {
        for (rate in listOf(16000, 48000, 44100)) {
            val converter = PcmFrames(rate)
            val input = ShortArray(rate / 10) { 1234 }
            val output = mutableListOf<ShortArray>()
            var position = 0
            while (position < input.size) {
                val n = minOf(157, input.size - position)
                converter.consume(input.copyOfRange(position, position + n), n) { output += it.copyOf() }
                position += n
            }
            assertEquals(5, output.size)
            assertTrue(output.all { it.size == 320 && it.all { sample -> sample == 1234.toShort() } })
            converter.consume(ShortArray(rate / 100) { 1000 }, rate / 100) { error("half frame") }
            converter.reset()
            converter.consume(ShortArray(rate / 50) { 2000 }, rate / 50) {
                assertTrue(it.all { sample -> sample == 2000.toShort() })
            }
        }
    }
}
