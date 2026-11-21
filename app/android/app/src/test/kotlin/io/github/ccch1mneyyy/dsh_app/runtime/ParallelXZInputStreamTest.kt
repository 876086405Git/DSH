package io.github.ccch1mneyyy.dsh_app.runtime

import org.junit.Assert.*
import org.junit.Test
import org.tukaani.xz.*
import java.io.*
import java.nio.file.Files
import java.util.concurrent.*
import java.util.zip.CRC32

class ParallelXZInputStreamTest {
    private class Fixture : AutoCloseable {
        val dir = Files.createTempDirectory("parallel-xz-test").toFile()
        val file = File(dir, "fixture.xz")
        val readers = CopyOnWriteArrayList<Tracked>()
        fun archive(blocks: List<ByteArray>) {
            XZOutputStream(FileOutputStream(file), LZMA2Options(0)).use { xz ->
                blocks.forEach { xz.write(it); xz.endBlock() }
            }
        }
        fun factory(): SeekableInputStream = Tracked(SeekableFileInputStream(file)).also { readers.add(it) }
        fun allClosed() { assertTrue(readers.isNotEmpty()); assertTrue(readers.all { it.closes == 1 }) }
        override fun close() { dir.deleteRecursively() }
    }
    private class Tracked(private val input: SeekableInputStream) : SeekableInputStream() {
        var closes = 0
        override fun read(): Int = input.read()
        override fun read(b: ByteArray, off: Int, len: Int): Int = input.read(b, off, len)
        override fun length(): Long = input.length()
        override fun position(): Long = input.position()
        override fun seek(pos: Long) = input.seek(pos)
        override fun close() { closes++; input.close() }
    }
    private fun field(stream: InputStream, name: String): Any? = stream.javaClass.getDeclaredField(name).also { it.isAccessible = true }.get(stream)
    private fun pattern(index: Int, size: Int = 131_073) = ByteArray(size) { (it * 13 + index).toByte() }
    private fun expectIo(action: () -> Unit) {
        try { action(); fail("expected IOException") } catch (_: IOException) { }
    }
    private fun corruptCheck(file: File, block: Int) {
        val at = SeekableXZInputStream(SeekableFileInputStream(file)).use { it.getBlockCompPos(block) + it.getBlockCompSize(block) - 1 }
        RandomAccessFile(file, "rw").use { raw -> raw.seek(at); val b = raw.read(); raw.seek(at); raw.write(b xor 1) }
    }

    @Test fun orderedBytesAcrossEightBlocksAndProgressCompletesOnlyOnConsumption() = Fixture().use { f ->
        val blocks = List(8) { pattern(it) }; f.archive(blocks)
        val progress = mutableListOf<Long>()
        ParallelXZInputStream.open(f::factory, progress::add).use { stream ->
            assertTrue(stream is ParallelXZInputStream)
            assertEquals(0, stream.read(ByteArray(1), 0, 0)); assertTrue(progress.isEmpty())
            assertArrayEquals(blocks.flatMap { it.asIterable() }.toByteArray(), stream.readBytes())
            assertEquals(-1, stream.read()); assertEquals(8, progress.size)
            assertTrue(progress.zipWithNext().all { (a,b) -> a < b }); assertEquals(f.file.length(), progress.last())
        }
        f.allClosed()
    }

    @Test fun onlyTwoOutputSlotsIncludingCurrentAndCompletedPending() = Fixture().use { f ->
        f.archive(List(6) { pattern(it, 1024) })
        ParallelXZInputStream.open(f::factory).use { stream ->
            val pending = field(stream, "pending") as Iterable<*>
            pending.forEach { (it as Future<*>).get(2, TimeUnit.SECONDS) }
            assertEquals(2, pending.count()); assertNull(field(stream, "current"))
            assertEquals(0, stream.read()); assertEquals(1, pending.count()); assertNotNull(field(stream, "current"))
            val rest = ByteArray(1023); assertEquals(1023, stream.read(rest)); assertNull(field(stream, "current"))
            assertEquals(2, field(stream, "nextBlock")); assertEquals(1, pending.count())
            assertEquals(1, stream.read()); assertEquals(3, field(stream, "nextBlock")); assertEquals(1, pending.count())
        }
        f.allClosed()
    }

    @Test fun crcFailureAtEveryBlockEndPropagatesAndClosesAllReaders() {
        repeat(3) { damaged -> Fixture().use { f ->
            f.archive(List(3) { pattern(it) }); corruptCheck(f.file, damaged)
            expectIo { ParallelXZInputStream.open(f::factory).use { it.readBytes() } }
            f.allClosed()
        } }
    }

    @Test fun truncatedIndexFailsBeforePublishingStreamAndClosesConstructorInput() = Fixture().use { f ->
        f.archive(List(2) { pattern(it) }); RandomAccessFile(f.file, "rw").use { it.setLength(it.length() - 7) }
        expectIo { ParallelXZInputStream.open(f::factory).close() }; f.allClosed()
    }

    @Test fun tarEndDoesNotHideCorruptionInLaterDecodedBlock() = Fixture().use { f ->
        f.archive(listOf(ByteArray(1024), pattern(9), pattern(10))); corruptCheck(f.file, 2)
        val output = File(f.dir,"output").apply { mkdirs() }
        expectIo { TarExtractor(output) {}.extractDecoded(ParallelXZInputStream.open(f::factory)) }
        f.allClosed(); assertTrue(output.listFiles()!!.isEmpty())
    }

    @Test fun singleBlockFallsBackBeforeAnyParallelWorkersAndReportsRawBytes() = Fixture().use { f ->
        val expected = pattern(4); f.archive(listOf(expected)); val progress = mutableListOf<Long>()
        ParallelXZInputStream.open(f::factory, progress::add).use { stream ->
            assertFalse(stream is ParallelXZInputStream); assertArrayEquals(expected, stream.readBytes())
        }
        assertEquals(f.file.length(), progress.last()); f.allClosed()
    }

    @Test fun oversizedBlockFallsBackBeforeExtraction() = Fixture().use { f ->
        val large = ByteArray(24 * 1024 * 1024 + 1) { 3 }; f.archive(listOf(large, byteArrayOf(4)))
        ParallelXZInputStream.open(f::factory).use { stream ->
            assertFalse(stream is ParallelXZInputStream)
            val actual = stream.readBytes(); assertEquals(large.size + 1, actual.size)
            assertTrue(actual.take(large.size).all { it == 3.toByte() }); assertEquals(4, actual.last().toInt())
        }
        f.allClosed()
    }

    @Test fun laterLargeDictionaryFallsBackBeforeTarWrites() = Fixture().use { f ->
        val blocks = List(2) { pattern(it, 2048) }; f.archive(blocks)
        val block = SeekableXZInputStream(SeekableFileInputStream(f.file)).use { it.getBlockCompPos(1) }
        // XZOutputStream with one LZMA2 filter emits flags=0, ID=0x21, property length=1.
        // Raise only the dictionary declaration to 64MiB and repair the header CRC.
        RandomAccessFile(f.file,"rw").use { raw ->
            raw.seek(block); val size = (raw.read() + 1) * 4; raw.seek(block)
            val header = ByteArray(size); raw.readFully(header)
            assertEquals(0, header[1].toInt()); assertEquals(0x21, header[2].toInt()); assertEquals(1, header[3].toInt())
            header[4] = 28
            val crc = CRC32().apply { update(header,0,size - 4) }.value
            repeat(4) { header[size - 4 + it] = (crc shr (8 * it)).toByte() }
            raw.seek(block); raw.write(header)
        }
        ParallelXZInputStream.open(f::factory).use { stream ->
            assertFalse(stream is ParallelXZInputStream)
            assertArrayEquals(blocks.flatMap { it.asIterable() }.toByteArray(), stream.readBytes())
        }
        f.allClosed()
    }

    @Test fun secondDecoderOpenFailureClosesPreflightReader() = Fixture().use { f ->
        f.archive(List(2) { pattern(it, 1024) }); var opened = 0
        expectIo { ParallelXZInputStream.open({
            if (opened++ == 2) throw IOException("synthetic second decoder open failure")
            f.factory()
        }).close() }
        f.allClosed()
    }

    @Test fun closeWithoutConsumptionTerminatesWorkersAndClosesReadersOnce() = Fixture().use { f ->
        f.archive(List(4) { pattern(it, 1024 * 1024) })
        val stream = ParallelXZInputStream.open(f::factory)
        stream.close(); stream.close(); f.allClosed()
        val workers = field(stream, "workers") as Array<*>
        assertTrue(workers.all { (it as ExecutorService).isTerminated })
        expectIo { stream.read() }
    }
}
