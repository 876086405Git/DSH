package io.github.ccch1mneyyy.dsh_app.phone.a11y

import android.os.Looper
import android.os.SystemClock

/**
 * Counts accessibility events (delivered on the main thread) so a worker thread can
 * wait for the UI to settle after an action: the first change, then a quiet gap.
 * Waiting on the main thread would block event delivery, so there it returns at once.
 */
internal class EventClock {
    @Suppress("PLATFORM_CLASS_MAPPED_TO_KOTLIN")
    private val lock = Object() // java.lang.Object for wait / notifyAll

    @Volatile var count = 0L
        private set

    @Volatile var lastAt = 0L
        private set

    @Volatile var lastPackage: String? = null
        private set

    /** Package → [count] at its latest content/text-change event. */
    private val contentAt = java.util.concurrent.ConcurrentHashMap<String, Long>()

    fun tick(packageName: CharSequence?, content: Boolean = false) {
        synchronized(lock) {
            count++
            lastAt = SystemClock.uptimeMillis()
            if (packageName != null) {
                val pkg = packageName.toString()
                lastPackage = pkg
                if (content) contentAt[pkg] = count
            }
            lock.notifyAll()
        }
    }

    /**
     * The app reported a content or text change after [since]. Some apps draw what matters
     * (a calculator's display) in views whose text never reaches the tree, but still send these.
     */
    fun contentChangedSince(packageName: String?, since: Long): Boolean =
        packageName != null && (contentAt[packageName] ?: Long.MIN_VALUE) > since

    /**
     * Waits for the first event after [since] (up to [firstMs]), then until [quietMs] pass
     * without events; never longer than [maxMs] in total. True if anything happened.
     */
    fun settle(since: Long, firstMs: Long, quietMs: Long, maxMs: Long, cancelled: () -> Boolean = { false }): Boolean {
        if (Looper.myLooper() == Looper.getMainLooper()) return count != since
        val start = SystemClock.uptimeMillis()
        val deadline = start + maxMs
        synchronized(lock) {
            while (count == since) {
                val left = minOf(start + firstMs, deadline) - SystemClock.uptimeMillis()
                if (left <= 0 || cancelled()) return false
                lock.wait(minOf(left, 100))
            }
            while (true) {
                val now = SystemClock.uptimeMillis()
                if (now >= deadline || cancelled()) return true
                val quietLeft = lastAt + quietMs - now
                if (quietLeft <= 0) return true
                lock.wait(minOf(quietLeft, deadline - now, 100).coerceAtLeast(1))
            }
        }
    }

    /** Sleeps up to [ms] in short slices, waking early on [cancelled]. */
    fun pause(ms: Long, cancelled: () -> Boolean = { false }) {
        if (Looper.myLooper() == Looper.getMainLooper()) return
        val end = SystemClock.uptimeMillis() + ms
        synchronized(lock) {
            while (true) {
                val left = end - SystemClock.uptimeMillis()
                if (left <= 0 || cancelled()) return
                lock.wait(minOf(left, 50))
            }
        }
    }
}
