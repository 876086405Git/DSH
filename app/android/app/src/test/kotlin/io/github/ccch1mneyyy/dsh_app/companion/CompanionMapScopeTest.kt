package io.github.ccch1mneyyy.dsh_app.companion

import org.junit.Assert.*
import org.junit.Test

class CompanionMapScopeTest {
    @Test fun aLateCloseFromTheOldPageCannotCloseTheNewExplicitAction() {
        val scopes = CompanionMapScopes()
        val first = scopes.open("light:first")
        val second = scopes.open("light:second")
        scopes.close(first.id)
        assertNull(scopes.current(first.id))
        assertEquals("light:second", scopes.current(second.id)!!.sourceSessionId)
        scopes.close(second.id)
        assertNull(scopes.current(second.id))
    }

    @Test fun lifecycleInvalidationCannotBeUndoneByReturningToTheSameRoom() {
        val scopes = CompanionMapScopes()
        val old = scopes.open("light:room")
        scopes.clear()
        assertNull(scopes.current(old.id))
        val fresh = scopes.open("light:room")
        assertNotEquals(old.id, fresh.id)
        assertNull(scopes.current(old.id))
        assertEquals(fresh, scopes.current(fresh.id))
    }
}
