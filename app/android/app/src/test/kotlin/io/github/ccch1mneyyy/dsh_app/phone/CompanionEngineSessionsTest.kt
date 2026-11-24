package io.github.ccch1mneyyy.dsh_app.phone

import org.junit.Assert.*
import org.junit.Test

class CompanionEngineSessionsTest {
    @Test fun onlyTheExactRegisteredSessionIsHers() {
        val hers = CompanionEngineSessions()
        assertTrue(hers.replace(listOf("4f1c2d", "9ab0")))
        assertTrue("4f1c2d" in hers)
        assertTrue("9ab0" in hers)
        // A name that looks like hers, a prefix or an extension of her id claims nothing.
        assertFalse("companion:room:t:r" in hers)
        assertFalse("4f1c" in hers)
        assertFalse("4f1c2d-x" in hers)
        assertFalse(null in hers)
    }

    @Test fun replacingDropsWhatIsNoLongerHers() {
        val hers = CompanionEngineSessions()
        hers.replace(listOf("a", "b"))
        assertTrue(hers.replace(listOf("b")))
        assertFalse("a" in hers)
        assertTrue("b" in hers)
        assertTrue(hers.replace(emptyList<String>()))
        assertTrue(hers.isEmpty())
        assertFalse("b" in hers)
    }

    @Test fun malformedRegistrationChangesNothing() {
        val hers = CompanionEngineSessions()
        hers.replace(listOf("a"))
        assertFalse(hers.replace(null))
        assertFalse(hers.replace("a"))
        assertFalse(hers.replace(listOf("b", 3)))
        assertFalse(hers.replace(listOf("")))
        assertFalse(hers.replace(listOf("bad\u0000id")))
        // A bad entry past the kept newest still fails the whole list.
        assertFalse(hers.replace(listOf(3) + List(64) { "s$it" }))
        assertTrue("a" in hers)
        assertFalse("s0" in hers)
        assertFalse("b" in hers)
    }

    @Test fun aLongListKeepsItsNewestAndDropsTheOldSet() {
        val hers = CompanionEngineSessions()
        hers.replace(listOf("retired"))
        assertTrue(hers.replace(List(65) { "s$it" }))
        assertFalse("retired" in hers)
        assertFalse("s0" in hers)
        assertTrue("s1" in hers)
        assertTrue("s64" in hers)
    }
}
