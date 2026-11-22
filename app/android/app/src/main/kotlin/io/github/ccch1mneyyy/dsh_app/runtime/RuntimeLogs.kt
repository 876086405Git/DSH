package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.BufferedOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/** Process-wide log ordering and batching; only the writer touches the rolling file. */
class RuntimeLogs(
    private val file: File,
    private val monotonicMillis: () -> Long,
    private val post: (() -> Unit) -> Unit,
    private val deliver: (List<Entry>) -> Unit,
    private val writer: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor {
        Thread(it, "dsh-logs").apply { isDaemon = true }
    },
) {
    data class Entry(val seq: Long, val line: String, val stream: String, internal val warning: Boolean = false) {
        internal val bytes = (line + "\n").toByteArray(Charsets.UTF_8)
        fun toMap(): Map<String, Any?> = mapOf("seq" to seq, "line" to line, "stream" to stream)
    }

    data class Snapshot(val entries: List<Entry>, val throughSeq: Long) {
        fun toMap(): Map<String, Any?> = mapOf("entries" to entries.map { it.toMap() }, "throughSeq" to throughSeq)
    }

    private class Pending {
        val entries = ArrayDeque<Entry>()
        var bytes = 0L
        var dropped = 0L
        var totalDropped = 0L

        fun add(entry: Entry) {
            val size = entry.bytes.size
            // A warning may itself be lost, but must not evict data and generate another warning.
            if (entry.warning && (size + bytes > QUEUE_BYTES || entries.size >= QUEUE_LINES)) return
            if (size > QUEUE_BYTES) {
                if (!entry.warning) { dropped++; totalDropped++ }
                return
            }
            while (size + bytes > QUEUE_BYTES || entries.size >= QUEUE_LINES) {
                val removed = removeFirst()
                if (!removed.warning) { dropped++; totalDropped++ }
            }
            entries.addLast(entry)
            bytes += size
        }

        fun removeFirst(): Entry = entries.removeFirst().also { bytes -= it.bytes.size }
        fun takeAll(): List<Entry> = entries.toList().also { entries.clear(); bytes = 0 }
    }

    private val guard = Object()
    private val ring = ArrayDeque<Entry>()
    private val disk = Pending()
    private val delivery = Pending()
    private var sequence = 0L
    private var scheduled: ScheduledFuture<*>? = null
    private var scheduleId = 0L
    private var mainPending = false
    private var writing = false
    private var diskPaused = false
    private var flushThrough = 0L
    private val flushes = mutableListOf<Pair<Long, CompletableFuture<Unit>>>()

    /** Live entries retain the token-only mask; only the disk copy uses full diagnostics rules. */
    fun accept(line: String, stream: String, storageLine: String = line) {
        val liveLine = CrashClassifier.redact(line)
        val diskLine = LogRedactor.redact(storageLine)
        synchronized(guard) {
            add(liveLine, stream, diskLine = diskLine)
            schedule(BATCH_MS)
        }
    }

    private fun add(line: String, stream: String, warning: Boolean = false, diskLine: String = line) {
        val stamp = if (stream == "system") "[mono=${monotonicMillis()}ms] " else ""
        val entry = Entry(++sequence, stamp + line, stream, warning)
        ring.addLast(entry)
        while (ring.size > RING_LINES) ring.removeFirst()
        disk.add(if (diskLine == line) entry else Entry(entry.seq, stamp + diskLine, stream, warning))
        delivery.add(entry)
    }

    fun snapshot(lines: Int): Snapshot = synchronized(guard) { Snapshot(ring.takeLast(lines), sequence) }
    fun recent(lines: Int): List<String> = synchronized(guard) { ring.takeLast(lines).map { it.line } }
    fun dropped(): Pair<Long, Long> = synchronized(guard) { disk.totalDropped to delivery.totalDropped }

    private fun schedule(delay: Long) {
        if (scheduled == null) {
            val id = ++scheduleId
            scheduled = writer.schedule({ drain(id) }, delay, TimeUnit.MILLISECONDS)
        }
    }

    /** Complete after the captured disk prefix has been attempted and its handle closed. */
    fun flush(): CompletableFuture<Unit> = synchronized(guard) {
        val result = CompletableFuture<Unit>()
        flushes.add(sequence to result)
        flushThrough = sequence
        completeFlushes()
        if (!result.isDone) {
            scheduled?.cancel(false)
            scheduled = null
            schedule(0)
        }
        result
    }

    private fun completeFlushes() {
        if (writing) return
        val pending = disk.entries.firstOrNull()?.seq ?: Long.MAX_VALUE
        val complete = flushes.filter { it.first < pending }
        flushes.removeAll(complete.toSet())
        complete.forEach { it.second.complete(Unit) }
    }

    private fun drain(id: Long) {
        val batch: List<Entry>
        val queueMain: Boolean
        synchronized(guard) {
            if (id != scheduleId) return
            scheduled = null
            val diskDropped = disk.dropped
            val deliveryDropped = delivery.dropped
            disk.dropped = 0
            delivery.dropped = 0
            if (diskDropped != 0L || deliveryDropped != 0L) {
                add("[dsh-app] log queue dropped: disk=$diskDropped delivery=$deliveryDropped", "system", warning = true)
            }
            queueMain = !mainPending && delivery.entries.isNotEmpty()
            if (queueMain) mainPending = true
            batch = if (diskPaused) emptyList() else disk.takeAll()
            writing = batch.isNotEmpty()
        }
        if (queueMain) post(::deliverPending)
        if (batch.isNotEmpty()) {
            try { append(batch) } catch (_: Exception) {}
        }
        synchronized(guard) {
            writing = false
            completeFlushes()
            guard.notifyAll()
            if ((!diskPaused && disk.entries.isNotEmpty()) || delivery.dropped != 0L || disk.dropped != 0L) {
                schedule(if ((disk.entries.firstOrNull()?.seq ?: Long.MAX_VALUE) <= flushThrough) 0 else BATCH_MS)
            }
        }
    }

    private fun deliverPending() {
        val entries = synchronized(guard) {
            mainPending = false
            delivery.takeAll()
        }
        deliver(entries)
    }

    private fun append(entries: List<Entry>) {
        file.parentFile?.mkdirs()
        var length = file.length()
        var output: BufferedOutputStream? = null
        try {
            for (entry in entries) {
                if (length > FILE_BYTES) {
                    output?.close()
                    output = null
                    if (!file.renameTo(File(file.path + ".1"))) throw IOException("log rotation failed")
                    length = 0
                }
                if (output == null) output = FileOutputStream(file, true).buffered()
                output.write(entry.bytes)
                length += entry.bytes.size
            }
        } finally { output?.close() }
    }

    /**
     * Stops disk writes for a reset, which deletes the log directory: false if the batch being
     * written didn't close within 5 s. The runtime worker calls [resumeDisk] afterwards either way.
     */
    fun pauseDisk(): Boolean {
        synchronized(guard) {
            diskPaused = true
            val cutoff = sequence
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            while (writing) {
                val left = deadline - System.nanoTime()
                if (left <= 0) return false
                TimeUnit.NANOSECONDS.timedWait(guard, left)
            }
            // The reset deletes these lines with the old file; the ring still has them.
            while (disk.entries.firstOrNull()?.let { it.seq <= cutoff } == true) disk.removeFirst()
            completeFlushes()
            return true
        }
    }

    fun resumeDisk() = synchronized(guard) {
        diskPaused = false
        if (disk.entries.isNotEmpty()) schedule(0)
    }

    companion object {
        private const val BATCH_MS = 100L
        private const val RING_LINES = 2000
        private const val QUEUE_LINES = 20_000
        private const val QUEUE_BYTES = 8L * 1024 * 1024
        private const val FILE_BYTES = 2L * 1024 * 1024
    }
}
