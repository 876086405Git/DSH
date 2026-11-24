package io.github.ccch1mneyyy.dsh_app.phone

/**
 * Her full-mode sessions on this phone's own engine, as the app last registered them. The person
 * asking her is the go-ahead, so these may operate the phone with 手机操控 off; the switch stays the
 * main agent's. Only the app's MethodChannel writes the set, and only the engine's own caller
 * attribution is compared with it: no tool argument or session name can claim a place here.
 */
internal class CompanionEngineSessions {
    @Volatile private var ids: Set<String> = emptySet()

    /**
     * Replaces the whole set. Past [MAX], only the last ones count (the app lists the newest
     * last): an old set never outlives a long list. Anything but a list of ids changes nothing.
     */
    fun replace(raw: Any?): Boolean {
        val list = raw as? List<*> ?: return false
        ids = list.map { PhoneCaller.identifier(it) ?: return false }.takeLast(MAX).toSet()
        return true
    }

    operator fun contains(sessionId: String?): Boolean = sessionId != null && sessionId in ids

    fun isEmpty(): Boolean = ids.isEmpty()

    private companion object {
        // One per character on this host; far below any real roster.
        const val MAX = 64
    }
}
