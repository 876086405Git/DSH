package io.github.ccch1mneyyy.dsh_app.phone

import java.util.concurrent.ConcurrentHashMap

/**
 * What DSH last said in each conversation that drives the phone — its own words in the chat, as
 * Dart reads them off the transcript (`setPhoneThought`) — for the island's card: what it thinks
 * next to what it does. Keyed by the conversation ([PhoneControl.taskSession]); Dart clears an
 * entry when its task ends. Any thread; [listener] hears every change (the overlay, on its own
 * thread hop).
 */
object PhoneThoughts {
    private val bySession = ConcurrentHashMap<String, String>()

    @Volatile var listener: (() -> Unit)? = null

    /** [text] for [session]; null or blank forgets it. Kept to [MAX_CHARS] from the end: the newest words matter. */
    fun set(session: String, text: String?) {
        val words = text?.trim()?.takeIf { it.isNotEmpty() }?.takeLast(MAX_CHARS)
        val changed = if (words == null) bySession.remove(session) != null else bySession.put(session, words) != words
        // A conversation that never said it was done can't pile up: only a handful drive the phone.
        if (bySession.size > MAX_SESSIONS) bySession.keys.filter { it != session }.take(bySession.size - MAX_SESSIONS).forEach(bySession::remove)
        if (changed) listener?.invoke()
    }

    fun get(session: String?): String? = session?.let(bySession::get)

    fun clear() {
        if (bySession.isEmpty()) return
        bySession.clear()
        listener?.invoke()
    }

    const val MAX_CHARS = 600
    private const val MAX_SESSIONS = 8
}
