package io.github.ccch1mneyyy.dsh_app.phone.a11y

import android.os.Build
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Text that some apps send only in events. vivo's calculator display (an EditText) reads ""
 * as a node while showing 12+3, yet its selection-changed events carry "12+3" and its result
 * view's carry "15". Without this the tree never changes when its keys are pressed.
 *
 * Events are recorded on the main thread; their sources are resolved later on the capturing
 * worker (a platform read each), and only for a window that has an empty-text node.
 */
internal class EventTexts {
    private val store = EventTextStore<AccessibilityEvent, AccessibilityNodeInfo>({ it.windowId }) { event ->
        try { if (Build.VERSION.SDK_INT >= 33) event.getSource(0) else event.source } catch (_: Exception) { null }
    }

    fun record(event: AccessibilityEvent) {
        if (event.eventType != AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED &&
            event.eventType != AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED) return
        if (event.isPassword) return
        // The platform reuses the event after this callback.
        @Suppress("DEPRECATION")
        val copy = if (Build.VERSION.SDK_INT >= 30) AccessibilityEvent(event) else AccessibilityEvent.obtain(event)
        store.add(copy, event.text.joinToString(""))
    }

    /** The newest event text for [node], or null when none is known. Worker thread only. */
    fun text(node: AccessibilityNodeInfo): String? = store.text(node, node.windowId)
}

/** [EventTexts]' bookkeeping, apart from Android types. Node equality is window + node id. */
internal class EventTextStore<E : Any, K : Any>(private val windowOf: (E) -> Int, private val sourceOf: (E) -> K?) {
    private class Pending<E>(val event: E, val text: String, val seq: Long)
    private class Known(val window: Int, val text: String)

    private val lock = Any()
    // One drain -> resolve -> commit at a time, so no reader sees a half-applied batch.
    private val resolving = Any()
    private var seq = 0L
    private val pending = ArrayDeque<Pending<E>>()
    /** Window -> newest event lost to the buffer limit; texts older than it may be outdated. */
    private val lostAt = HashMap<Int, Long>()
    private val known = object : LinkedHashMap<K, Known>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<K, Known>?) = size > MAX_KNOWN
    }

    /** An empty [text] counts too: a cleared field must not keep showing its old text. */
    fun add(event: E, text: String) = synchronized(lock) {
        pending.addLast(Pending(event, text, ++seq))
        while (pending.size > MAX_PENDING) {
            // The dropped event may have cleared or changed a field: forget its window's texts.
            val lost = pending.removeFirst()
            val window = windowOf(lost.event)
            known.values.removeAll { it.window == window }
            lostAt[window] = lost.seq
        }
    }

    fun text(key: K, window: Int): String? = synchronized(resolving) {
        val mine = synchronized(lock) {
            val out = pending.filter { windowOf(it.event) == window }
            if (out.isNotEmpty()) pending.removeAll { windowOf(it.event) == window }
            out
        }
        // Oldest first, so the newest text of each source wins.
        for (p in mine) {
            val source = sourceOf(p.event) ?: continue
            synchronized(lock) {
                // A newer event of this window was dropped while this one resolved.
                if (p.seq > (lostAt[window] ?: 0L)) known[source] = Known(window, p.text)
            }
        }
        synchronized(lock) { known[key]?.text }
    }

    private companion object {
        const val MAX_PENDING = 32
        const val MAX_KNOWN = 64
    }
}
