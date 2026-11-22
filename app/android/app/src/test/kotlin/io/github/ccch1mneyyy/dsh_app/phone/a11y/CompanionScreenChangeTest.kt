package io.github.ccch1mneyyy.dsh_app.phone.a11y

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CompanionScreenChangeTest {
    @Test fun stableMinuteVisualDifferenceAndTextChangeUseTheRealGridTrigger() {
        val changes = CompanionScreenChange()
        val unchanged = ByteArray(64 * 36)
        assertTrue(changes.changed(unchanged, 0, false))
        assertFalse(changes.changed(unchanged, 59999, false))
        assertTrue(changes.changed(unchanged, 60000, false))
        assertTrue(changes.changed(ByteArray(64 * 36) { 12 }, 60001, false))
        assertFalse(changes.changed(ByteArray(64 * 36) { 13 }, 62000, false))
        assertTrue(changes.changed(ByteArray(64 * 36) { 13 }, 64000, true))
        changes.clear()
        assertTrue(changes.changed(ByteArray(64 * 36) { 13 }, 64001, false))
    }
}
