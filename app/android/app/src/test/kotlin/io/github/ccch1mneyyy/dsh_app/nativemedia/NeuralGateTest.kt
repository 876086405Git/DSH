package io.github.ccch1mneyyy.dsh_app.nativemedia

import io.github.ccch1mneyyy.dsh_app.nativemedia.SpeechGate.Edge
import java.util.concurrent.AbstractExecutorService
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NeuralGateTest {
    private class Vad : NeuralGate.VadModel {
        var value = 0f
        var resets = 0
        var closed = false
        override fun probability(frame: ShortArray) = value
        override fun reset() { resets++ }
        override fun close() { closed = true }
    }

    private class Turn(var value: Float = 1f) : NeuralGate.TurnModel {
        var calls = 0
        var input = FloatArray(0)
        var closed = false
        var fails = false
        override fun probability(audio: FloatArray): Float {
            calls++
            if (fails) throw IllegalStateException("broken")
            input = audio.copyOf()
            return value
        }
        override fun close() { closed = true }
    }

    private class Worker : AbstractExecutorService() {
        val tasks = ArrayDeque<Runnable>()
        private var stopped = false
        override fun execute(command: Runnable) { tasks.addLast(command) }
        fun runNext() { tasks.removeFirst().run() }
        override fun shutdown() { stopped = true }
        override fun shutdownNow(): MutableList<Runnable> {
            stopped = true
            return tasks.toMutableList().also { tasks.clear() }
        }
        override fun isShutdown() = stopped
        override fun isTerminated() = stopped && tasks.isEmpty()
        override fun awaitTermination(timeout: Long, unit: TimeUnit) = isTerminated
    }

    /** [pause]: 快 by default here, the timings these tests were written for. */
    private class Capture(echoCancelled: Boolean = true, pause: TurnPause = TurnPause.QUICK) : AutoCloseable {
        val vad = Vad()
        val turn = Turn()
        val worker = Worker()
        val failures = mutableListOf<Exception>()
        val gate = NeuralGate(vad, turn, echoCancelled, worker, { failures += it }, pause)
        var now = 0L
        private val frame = ShortArray(320)
        fun feed(probability: Float, frames: Int, sample: Short = 1000): List<Edge> {
            vad.value = probability
            frame.fill(sample)
            val edges = mutableListOf<Edge>()
            repeat(frames) {
                val edge = gate.consume(frame, -30.0, now)
                now += 20
                if (edge != Edge.NONE) edges += edge
            }
            return edges
        }
        override fun close() {
            gate.close()
            while (worker.tasks.isNotEmpty()) worker.runNext()
        }
    }

    @Test fun aFailedTurnModelEndsThePauseAfterTheHangoverAndIsReportedOnce() {
        Capture().use { c ->
            c.turn.fails = true
            assertEquals(listOf(Edge.START), c.feed(0.9f, 6))
            assertEquals(emptyList<Edge>(), c.feed(0.1f, 10))
            c.worker.runNext()
            // Not ended by the failure: 680 ms of quiet is still the turn.
            assertEquals(emptyList<Edge>(), c.feed(0.1f, 24))
            assertEquals(listOf(Edge.END), c.feed(0.1f, 1))
            c.worker.runNext()
            assertEquals(listOf(Edge.START), c.feed(0.9f, 6))
            assertEquals(emptyList<Edge>(), c.feed(0.1f, 10))
            c.worker.runNext()
            assertEquals(emptyList<Edge>(), c.feed(0.1f, 1))
            assertEquals(1, c.failures.size)
        }
    }

    @Test fun opensAfterContinuousSpeechAndRaisesTheBarDuringPlayback() {
        Capture().use { c ->
            assertEquals(emptyList<Edge>(), c.feed(0.9f, 5))
            assertEquals(emptyList<Edge>(), c.feed(0.1f, 1))
            assertEquals(listOf(Edge.START), c.feed(0.9f, 6))
            c.gate.reset()
            c.gate.setPlaying(true, c.now)
            assertEquals(emptyList<Edge>(), c.feed(0.9f, 20))
            assertEquals(emptyList<Edge>(), c.feed(0.6f, 20))
            assertEquals(emptyList<Edge>(), c.feed(0.9f, 9))
            assertEquals(listOf(Edge.START), c.feed(0.9f, 1))
        }
        Capture(echoCancelled = false).use { c ->
            c.gate.setPlaying(true, c.now)
            assertEquals(emptyList<Edge>(), c.feed(0.8f, 40))
            assertEquals(listOf(Edge.START), c.feed(0.9f, 10))
        }
    }

    @Test fun waitsForTwoHundredMillisecondsThenEmitsEndOnTheCaptureThread() {
        Capture().use { c ->
            assertEquals(listOf(Edge.START), c.feed(0.9f, 6))
            assertEquals(emptyList<Edge>(), c.feed(0.1f, 9, 0))
            assertTrue(c.worker.tasks.isEmpty())
            assertEquals(emptyList<Edge>(), c.feed(0.1f, 1, 0))
            assertEquals(1, c.worker.tasks.size)
            assertEquals(0, c.turn.calls)
            c.worker.runNext()
            assertEquals(1, c.turn.calls)
            assertEquals(128000, c.turn.input.size)
            assertEquals(0f, c.turn.input[0], 0f)
            assertEquals(1000f / 32768f, c.turn.input[128000 - 3200 - 1], 0f)
            assertEquals(0f, c.turn.input.last(), 0f)
            assertEquals(listOf(Edge.END), c.feed(0.1f, 1, 0))
            assertEquals(emptyList<Edge>(), c.feed(0.1f, 20, 0))
        }
    }

    @Test fun anIncompleteTurnIsCheckedAgainAfterAnotherTwoHundredMilliseconds() {
        Capture().use { c ->
            c.turn.value = 0.3f
            c.feed(0.9f, 6)
            c.feed(0.1f, 10)
            c.worker.runNext()
            assertEquals(emptyList<Edge>(), c.feed(0.1f, 9))
            assertTrue(c.worker.tasks.isEmpty())
            assertEquals(emptyList<Edge>(), c.feed(0.1f, 1))
            assertEquals(1, c.worker.tasks.size)
            c.turn.value = 0.5f
            c.worker.runNext()
            assertEquals(listOf(Edge.END), c.feed(0.1f, 1))
        }
    }

    @Test fun aPredictionFromBeforeSpeechResumesCannotEndTheTurn() {
        Capture().use { c ->
            c.feed(0.9f, 6)
            c.feed(0.1f, 10)
            assertEquals(emptyList<Edge>(), c.feed(0.9f, 1, 2000))
            c.worker.runNext()
            assertEquals(emptyList<Edge>(), c.feed(0.1f, 10, 0))
            assertEquals(1, c.worker.tasks.size)
            c.worker.runNext()
            assertEquals(listOf(Edge.END), c.feed(0.1f, 1, 0))
        }
    }

    @Test fun normalBelievesTheModelOnlyAfterSixHundredMillisecondsOfQuiet() {
        Capture(pause = TurnPause.NORMAL).use { c ->
            c.feed(0.9f, 6)
            c.feed(0.1f, 10)
            c.worker.runNext()
            // The model says done at 200 ms: a breath mid-sentence, not yet the end.
            assertEquals(emptyList<Edge>(), c.feed(0.1f, 19))
            assertEquals(listOf(Edge.END), c.feed(0.1f, 1))
        }
    }

    @Test fun aDoneTakenBackByALaterCheckDoesNotEndTheTurn() {
        Capture(pause = TurnPause.NORMAL).use { c ->
            c.feed(0.9f, 6)
            c.feed(0.1f, 10)
            c.worker.runNext()
            c.feed(0.1f, 10)
            c.turn.value = 0.2f
            c.worker.runNext()
            assertEquals(emptyList<Edge>(), c.feed(0.1f, 20))
        }
    }

    @Test fun aFailedCheckAfterADoneEndsAfterTheHangoverNotTheDoneWait() {
        Capture(pause = TurnPause.NORMAL).use { c ->
            c.feed(0.9f, 6)
            c.feed(0.1f, 10)
            c.worker.runNext()
            c.feed(0.1f, 10)
            c.turn.fails = true
            c.worker.runNext()
            // 600 ms would have been the done wait; a failed check waits the 1 s hangover.
            assertEquals(emptyList<Edge>(), c.feed(0.1f, 29))
            assertEquals(listOf(Edge.END), c.feed(0.1f, 1))
        }
    }

    @Test fun patientWaitsLongerAndAChangeMidPauseAppliesAtOnce() {
        Capture(pause = TurnPause.PATIENT).use { c ->
            c.feed(0.9f, 6)
            c.feed(0.1f, 10)
            c.worker.runNext()
            assertEquals(emptyList<Edge>(), c.feed(0.1f, 40))
            // Switched to 快 in the middle of the pause: the model's done holds now.
            c.gate.pause = TurnPause.QUICK
            assertEquals(listOf(Edge.END), c.feed(0.1f, 1))
        }
        Capture(pause = TurnPause.PATIENT).use { c ->
            c.feed(0.9f, 6)
            c.feed(0.1f, 10)
            c.worker.runNext()
            assertEquals(emptyList<Edge>(), c.feed(0.1f, 49))
            assertEquals(listOf(Edge.END), c.feed(0.1f, 1))
        }
    }

    @Test fun threeSecondsOfSilenceEndsEvenWhenInferenceHasNotReturned() {
        Capture().use { c ->
            c.feed(0.9f, 6)
            assertEquals(emptyList<Edge>(), c.feed(0.1f, 149))
            assertEquals(1, c.worker.tasks.size)
            assertEquals(listOf(Edge.END), c.feed(0.1f, 1))
            assertEquals(listOf(Edge.START), c.feed(0.9f, 6))
            c.worker.runNext()
            assertEquals(emptyList<Edge>(), c.feed(0.1f, 1))
        }
    }

    @Test fun longTurnsEndAtOneHundredAndTenSecondsIncludingPreroll() {
        Capture().use { c ->
            c.feed(0.1f, 20)
            assertEquals(listOf(Edge.START), c.feed(0.9f, 6))
            assertEquals(emptyList<Edge>(), c.feed(0.9f, 5483))
            assertEquals(listOf(Edge.END), c.feed(0.9f, 1))
        }
    }

    @Test fun aResetDropsAudioAndOldResultsWithoutReusingThePendingInput() {
        Capture().use { c ->
            c.feed(0.9f, 6)
            c.feed(0.1f, 10)
            c.gate.reset()
            c.gate.reset()
            assertEquals(1, c.vad.resets)
            assertEquals(listOf(Edge.START), c.feed(0.9f, 6, 2000))
            c.worker.runNext()
            assertEquals(emptyList<Edge>(), c.feed(0.1f, 10, 0))
            c.worker.runNext()
            assertEquals(0f, c.turn.input[128000 - 5120 - 1], 0f)
            assertEquals(2000f / 32768f, c.turn.input[128000 - 3200 - 1], 0f)
            assertEquals(listOf(Edge.END), c.feed(0.1f, 1))
        }
    }

    @Test fun aFrameLongerThanTheRingWrapsFromANonzeroPosition() {
        Capture().use { c ->
            c.feed(0.9f, 6)
            val frame = ShortArray(NeuralGate.WINDOW_SAMPLES + 37) { it.toShort() }
            c.gate.consume(frame, -30.0, c.now)
            c.feed(0.1f, 10, 0)
            c.worker.runNext()
            val quiet = 10 * 320
            val kept = NeuralGate.WINDOW_SAMPLES - quiet
            for (i in 0 until kept) {
                assertEquals(frame[frame.size - kept + i] / 32768f, c.turn.input[i], 0f)
            }
            for (i in kept until NeuralGate.WINDOW_SAMPLES) assertEquals(0f, c.turn.input[i], 0f)
        }
    }

    @Test fun theModelOnlySeesTheLastEightSeconds() {
        Capture().use { c ->
            c.feed(0.9f, 6, 1000)
            c.feed(0.9f, 390, 2000)
            c.feed(0.1f, 10, 0)
            c.worker.runNext()
            assertEquals(2000f / 32768f, c.turn.input.first(), 0f)
            assertEquals(2000f / 32768f, c.turn.input[128000 - 3200 - 1], 0f)
            assertEquals(0f, c.turn.input.last(), 0f)
            assertFalse(c.turn.input.any { it == 1000f / 32768f })
        }
    }

    @Test(timeout = 5000) fun closeReleasesTheTurnModelOnlyAfterItsInferenceWithoutWaiting() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val closed = CountDownLatch(1)
        val worker = Executors.newSingleThreadExecutor()
        val vad = Vad().apply { value = 0.9f }
        val turn = object : NeuralGate.TurnModel {
            override fun probability(audio: FloatArray): Float {
                entered.countDown()
                release.await()
                return 1f
            }
            override fun close() { closed.countDown() }
        }
        val gate = NeuralGate(vad, turn, worker = worker)
        try {
            val frame = ShortArray(320)
            repeat(6) { gate.consume(frame, -20.0, it * 20L) }
            vad.value = 0f
            repeat(10) { gate.consume(frame, -100.0, 120 + it * 20L) }
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            gate.close()
            assertTrue(vad.closed)
            assertFalse(closed.await(20, TimeUnit.MILLISECONDS))
            release.countDown()
            assertTrue(closed.await(2, TimeUnit.SECONDS))
            assertTrue(worker.awaitTermination(2, TimeUnit.SECONDS))
        } finally {
            release.countDown()
            worker.shutdownNow()
        }
    }
}
