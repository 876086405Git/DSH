package io.github.ccch1mneyyy.dsh_app.companion

import java.util.UUID

/** One explicit handoff's current room; no timer, heartbeat, or persisted authority. */
internal class CompanionMapScopes {
    data class Owner(val id: String, val sourceSessionId: String)
    private var owner: Owner? = null

    @Synchronized fun open(sourceSessionId: String): Owner {
        require(sourceSessionId.isNotBlank() && sourceSessionId.length <= 256)
        return Owner(UUID.randomUUID().toString(), sourceSessionId).also { owner = it }
    }

    @Synchronized fun current(scopeId: String): Owner? = owner?.takeIf { it.id == scopeId }
    @Synchronized fun close(scopeId: String) { if (owner?.id == scopeId) owner = null }
    @Synchronized fun clear() { owner = null }
}
