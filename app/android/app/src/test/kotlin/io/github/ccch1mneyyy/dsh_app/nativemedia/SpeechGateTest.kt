package io.github.ccch1mneyyy.dsh_app.nativemedia

import io.github.ccch1mneyyy.dsh_app.nativemedia.SpeechGate.Edge
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class SpeechGateTest {
    private var now = 0L

    /** Feeds [frames] frames at [db]; the edges they made. */
    private fun SpeechGate.feed(db: Double, frames: Int): List<Edge> =
        (0 until frames).map { consume(db, now).also { now += SpeechGate.FRAME_MS } }.filter { it != Edge.NONE }

    @Test fun quietRoomThenSpeechStartsAndEnds() {
        val g = SpeechGate()
        assertEquals(emptyList<Edge>(), g.feed(-62.0, 100)) // 2 s of room noise
        // 100 ms of speech is a cough, not speech.
        assertEquals(emptyList<Edge>(), g.feed(-30.0, 5))
        assertEquals(emptyList<Edge>(), g.feed(-62.0, 10))
        // 120 ms makes a start, once.
        assertEquals(listOf(Edge.START), g.feed(-30.0, 40))
        assertTrue(g.isSpeaking)
        // A short pause inside the sentence does not end it.
        assertEquals(emptyList<Edge>(), g.feed(-62.0, 20))
        assertEquals(emptyList<Edge>(), g.feed(-30.0, 10))
        // A second of quiet does (适中).
        assertEquals(emptyList<Edge>(), g.feed(-62.0, 49))
        assertEquals(listOf(Edge.END), g.feed(-62.0, 1))
    }

    @Test fun quickAndPatientEndSoonerAndLater() {
        for ((pause, frames) in listOf(TurnPause.QUICK to 35, TurnPause.PATIENT to 80)) {
            val g = SpeechGate(pause = pause)
            g.feed(-62.0, 100)
            g.feed(-30.0, 10)
            assertEquals(emptyList<Edge>(), g.feed(-62.0, frames - 1))
            assertEquals(listOf(Edge.END), g.feed(-62.0, 1))
        }
    }

    @Test fun theClipsEchoIsHeldToAHigherBar() {
        val g = SpeechGate(echoCancelled = true)
        g.feed(-62.0, 100)
        g.setPlaying(true, now)
        // Residual echo 20 dB over the floor: below the playing margin (24 dB), never speech.
        assertEquals(emptyList<Edge>(), g.feed(-42.0, 200))
        // A voice close to the phone, well over it, still is.
        assertEquals(listOf(Edge.START), g.feed(-25.0, 20))
    }

    @Test fun theEchoDoesNotLiftTheFloor() {
        val g = SpeechGate()
        g.feed(-62.0, 100)
        g.setPlaying(true, now)
        g.feed(-42.0, 500) // 10 s of loud clip
        g.setPlaying(false, now)
        // Back to quiet: ordinary speech at the ordinary margin starts at once.
        assertEquals(listOf(Edge.START), g.feed(-44.0, 10))
    }

    @Test fun theFirstMomentsOfAClipAreIgnored() {
        val g = SpeechGate()
        g.feed(-62.0, 100)
        g.setPlaying(true, now)
        // The echo canceller is still adapting: even loud frames don't count yet.
        assertEquals(emptyList<Edge>(), g.feed(-20.0, (SpeechGate.SETTLE_MS / SpeechGate.FRAME_MS).toInt()))
        assertEquals(listOf(Edge.START), g.feed(-20.0, SpeechGate.PLAY_START_FRAMES))
    }

    @Test fun withoutEchoCancellationTheBarIsHigherStill() {
        val g = SpeechGate(echoCancelled = false)
        g.feed(-62.0, 100)
        g.setPlaying(true, now)
        g.feed(-62.0, 30)
        assertEquals(emptyList<Edge>(), g.feed(-35.0, 100)) // 27 dB over the floor
        assertEquals(listOf(Edge.START), g.feed(-28.0, 20))
    }

    @Test fun levels() {
        assertEquals(-100.0, SpeechGate.levelOf(ShortArray(320), 320), 0.0)
        val full = ShortArray(320) { if (it % 2 == 0) Short.MAX_VALUE else Short.MIN_VALUE }
        assertEquals(0.0, SpeechGate.levelOf(full, 320), 0.01)
        assertEquals(-100.0, SpeechGate.levelOf(full, 0), 0.0)
    }
}
