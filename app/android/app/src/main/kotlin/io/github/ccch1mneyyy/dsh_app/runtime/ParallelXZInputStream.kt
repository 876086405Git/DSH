package io.github.ccch1mneyyy.dsh_app.runtime

import org.tukaani.xz.BasicArrayCache
import org.tukaani.xz.MemoryLimitException
import org.tukaani.xz.SeekableInputStream
import org.tukaani.xz.SeekableXZInputStream
import org.tukaani.xz.XZInputStream
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import java.io.InterruptedIOException
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.TimeUnit

/** Single tar consumer; two decoded blocks total, including its current block. */
internal class ParallelXZInputStream private constructor(
    private val decoders: Array<SeekableXZInputStream>,
    private val sizes: IntArray,
    private val progress: LongArray,
    private val onProgress: (Long) -> Unit,
) : InputStream() {
    private val workers = Array(2) { i ->
        Executors.newSingleThreadExecutor { Thread(it, "dsh-xz-$i") }
    }
    private val pending = ArrayDeque<Future<ByteArray>>()
    private var nextBlock = 0
    private var consumed = 0
    private var current: ByteArray? = null
    private var recycled: ByteArray? = null
    private var offset = 0
    @Volatile private var closed = false

    init { submit(); submit() }

    private fun submit() {
        if (nextBlock == sizes.size) return
        val block = nextBlock++
        val buffer = recycled
        recycled = null
        pending.addLast(workers[block % 2].submit<ByteArray> {
            val decoder = decoders[block % 2]
            decoder.seekToBlock(block)
            val bytes = buffer ?: ByteArray(sizes[block])
            var at = 0
            while (at < bytes.size) {
                if (closed) throw InterruptedIOException("xz decoding cancelled")
                val read = decoder.read(bytes, at, minOf(64 * 1024, bytes.size - at))
                if (read < 0) throw IOException("truncated xz block")
                at += read
            }
            // XZ verifies the block check when the declared final byte is read.
            bytes
        })
    }

    override fun read(): Int {
        val one = ByteArray(1)
        return if (read(one, 0, 1) < 0) -1 else one[0].toInt() and 0xff
    }

    override fun read(bytes: ByteArray, off: Int, len: Int): Int {
        if (closed) throw IOException("xz stream closed")
        if (len == 0) return 0
        try {
            if (current == null) {
                if (pending.size < 2) submit()
                if (pending.isEmpty()) return -1
                current = pending.removeFirst().get()
                offset = 0
            }
            val block = current!!
            val count = minOf(len, block.size - offset)
            block.copyInto(bytes, off, offset, offset + count)
            offset += count
            if (offset == block.size) {
                current = null
                // Only the next submit can take this block, after its last byte was copied out.
                if (nextBlock < sizes.size && sizes[nextBlock] == block.size) recycled = block
                onProgress(progress[consumed++])
            }
            return count
        } catch (e: Exception) {
            val cause = (e as? ExecutionException)?.cause ?: e
            try { close() } catch (cleanup: Exception) { cause.addSuppressed(cleanup) }
            throw cause
        }
    }

    override fun close() {
        if (closed) return
        closed = true
        recycled = null
        workers.forEach { it.shutdownNow() }
        // A decoder isn't safe to close under a read; a block read stops within 64 KiB.
        workers.forEach { it.awaitTermination(1, TimeUnit.MINUTES) }
        try { decoders[0].close() } finally { decoders[1].close() }
    }

    companion object {
        private const val MAX_BLOCK_BYTES = 24L * 1024 * 1024
        private const val DECODER_MEMORY_KIB = 32 * 1024

        fun open(factory: () -> SeekableInputStream, onProgress: (Long) -> Unit = {}): InputStream {
            var first: SeekableXZInputStream? = null
            var second: SeekableXZInputStream? = null
            val cache = BasicArrayCache()
            try {
                first = decoder(factory, cache)
                val count = first.blockCount
                if (count < 2 || (0 until count).any { first.getBlockSize(it) !in 1..MAX_BLOCK_BYTES }) {
                    first.close()
                    return sequential(factory, onProgress)
                }
                val sizes = IntArray(count) { first.getBlockSize(it).toInt() }
                val progress = LongArray(count) { block ->
                    if (block + 1 < count) first.getBlockCompPos(block + 1) else factory().use { it.length() }
                }
                // Block filter/dictionary memory is only known when a read initializes
                // that block. Check every header before tar can write anything.
                repeat(count) { block -> first.seekToBlock(block); first.read() }
                second = decoder(factory, cache)
                return ParallelXZInputStream(arrayOf(first, second), sizes, progress, onProgress)
            } catch (_: MemoryLimitException) {
                first?.close()
                second?.close()
                return sequential(factory, onProgress)
            } catch (e: Throwable) {
                try { first?.close() } catch (cleanup: Exception) { e.addSuppressed(cleanup) }
                try { second?.close() } catch (cleanup: Exception) { e.addSuppressed(cleanup) }
                throw e
            }
        }

        private fun decoder(factory: () -> SeekableInputStream, cache: BasicArrayCache): SeekableXZInputStream {
            val raw = factory()
            try { return SeekableXZInputStream(raw, DECODER_MEMORY_KIB, true, cache) }
            catch (e: Throwable) {
                try { raw.close() } catch (cleanup: Exception) { e.addSuppressed(cleanup) }
                throw e
            }
        }

        private fun sequential(factory: () -> SeekableInputStream, onProgress: (Long) -> Unit): InputStream {
            val counting = object : FilterInputStream(factory()) {
                var count = 0L
                override fun read(): Int = `in`.read().also { if (it >= 0) onProgress(++count) }
                override fun read(b: ByteArray, off: Int, len: Int): Int = `in`.read(b, off, len).also {
                    if (it > 0) { count += it; onProgress(count) }
                }
            }
            try { return XZInputStream(counting) }
            catch (e: Throwable) {
                try { counting.close() } catch (cleanup: Exception) { e.addSuppressed(cleanup) }
                throw e
            }
        }
    }
}
