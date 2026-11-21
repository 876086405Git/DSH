package io.github.ccch1mneyyy.dsh_app.update.privileged

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Test

class SelfUpdateStreamsTest {
    private fun hash(bytes: ByteArray) = SelfUpdatePolicy.hash(ByteArrayInputStream(bytes))

    @Test fun fullDuplexConsumesExactSizeAndReturnsWithoutStdinEof() {
        val bytes = ByteArray(128 * 1024) { (it % 251).toByte() }
        val peerInput = PipedInputStream(1024)
        val clientOutput = PipedOutputStream(peerInput)
        val clientInput = PipedInputStream(1024)
        val peerOutput = PipedOutputStream(clientInput)
        val responded = AtomicBoolean(false)
        val closedBeforeResponse = AtomicBoolean(false)
        val peer = Thread({
            val received = ByteArrayOutputStream()
            val buffer = ByteArray(1024)
            while (received.size() < bytes.size) {
                val n = peerInput.read(buffer, 0, minOf(buffer.size, bytes.size - received.size()))
                check(n > 0)
                received.write(buffer, 0, n)
            }
            assertArrayEquals(bytes, received.toByteArray())
            responded.set(true)
            peerOutput.write("Success\n".toByteArray())
            peerOutput.close()
        }, "test-package-service").apply { isDaemon = true; start() }
        val output = object : OutputStream() {
            override fun write(b: Int) = clientOutput.write(b)
            override fun write(b: ByteArray, off: Int, len: Int) = clientOutput.write(b, off, len)
            override fun flush() = clientOutput.flush()
            override fun close() {
                if (!responded.get()) closedBeforeResponse.set(true)
                clientOutput.close()
            }
        }
        val result = SelfUpdateStreams.exchange(ByteArrayInputStream(bytes), bytes.size.toLong(), hash(bytes),
            clientInput, output, timeoutMs = 3000, close = { output.close(); clientInput.close() })
        peer.join(2000)
        assertFalse(peer.isAlive)
        assertTrue(responded.get())
        assertFalse(closedBeforeResponse.get())
        assertEquals("success", result.status)
    }

    @Test fun deadlineAndDisconnectAreUnknownNeverRetried() {
        val closed = CountDownLatch(1)
        val input = object : InputStream() {
            override fun read(): Int { closed.await(); return -1 }
            override fun close() { closed.countDown() }
        }
        val bytes = byteArrayOf(1)
        val started = System.nanoTime()
        val result = SelfUpdateStreams.exchange(ByteArrayInputStream(bytes), 1, hash(bytes), input,
            ByteArrayOutputStream(), timeoutMs = 30, close = { input.close() })
        assertTrue(result.outcomeUnknown)
        assertTrue(result.submitted)
        assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started) < 2000)
        assertEquals(0L, closed.count)
    }

    @Test fun outputOverflowIsDrainedButCannotBecomeSuccess() {
        val bytes = byteArrayOf(1)
        val text = "x".repeat(SelfUpdatePolicy.MAX_OUTPUT_BYTES) + "Success\n"
        val result = SelfUpdateStreams.exchange(ByteArrayInputStream(bytes), 1, hash(bytes),
            ByteArrayInputStream(text.toByteArray()), ByteArrayOutputStream(), close = {})
        assertTrue(result.outcomeUnknown)
    }

    @Test fun writerFailureMakesSuccessUnknown() {
        val bytes = byteArrayOf(1)
        val output = object : OutputStream() { override fun write(b: Int) { throw IOException("broken") } }
        val result = SelfUpdateStreams.exchange(ByteArrayInputStream(bytes), 1, hash(bytes),
            ByteArrayInputStream("Success\n".toByteArray()), output, close = {})
        assertTrue(result.outcomeUnknown)
    }

    @Test fun explicitFinalRejectionIsNotLostWhenItBreaksWriter() {
        val bytes = byteArrayOf(1)
        val output = object : OutputStream() { override fun write(b: Int) { throw IOException("rejected") } }
        val result = SelfUpdateStreams.exchange(ByteArrayInputStream(bytes), 1, hash(bytes),
            ByteArrayInputStream("Failure [INSTALL_FAILED_USER_RESTRICTED]\n".toByteArray()), output, close = {})
        assertEquals("blocked", result.status)
        assertFalse(result.outcomeUnknown)
    }

    @Test fun adbFinalResultDoesNotWaitForEof() {
        for ((text, status) in listOf(
            "Success\n" to "success",
            "Failure [INSTALL_FAILED_INSUFFICIENT_STORAGE:\nnot enough space]\n" to "storage",
        )) {
            val data = ByteArrayInputStream(text.toByteArray())
            // A final libadb WRTE can be readable even though EOF and available() are not.
            val input = object : InputStream() {
                override fun read(): Int = data.read().also { if (it < 0) throw IOException("Stream closed.") }
                override fun read(b: ByteArray, off: Int, len: Int): Int =
                    data.read(b, off, len).also { if (it < 0) throw IOException("Stream closed.") }
                override fun available(): Int = throw IOException("Stream closed.")
            }
            val bytes = byteArrayOf(1, 2, 3)
            val output = ByteArrayOutputStream()
            val result = SelfUpdateStreams.exchange(ByteArrayInputStream(bytes), bytes.size.toLong(), hash(bytes),
                input, output, endAtAdbResultLine = true, close = {})
            assertEquals(status, result.status)
            assertFalse(result.outcomeUnknown)
            if (status == "success") assertArrayEquals(bytes, output.toByteArray())
        }
    }
}
