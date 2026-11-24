package io.github.ccch1mneyyy.dsh_app.phone.a11y

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** vivo's calculator: the display and result EditTexts read "" as nodes; their events carry the text. */
class EventTextStoreTest {
    private data class Event(val window: Int, val source: String?)

    private var resolved = 0
    private val store = EventTextStore<Event, String>({ it.window }) { resolved++; it.source }

    @Test fun eachSourceKeepsItsNewestText() {
        // One key press: the display's selection events, then the result line's.
        store.add(Event(7, "formula"), "12+")
        store.add(Event(7, "formula"), "12+3")
        store.add(Event(7, "result"), "15")
        assertEquals("12+3", store.text("formula", 7))
        assertEquals("15", store.text("result", 7))
        assertNull(store.text("other", 7))
    }

    @Test fun aClearedFieldDoesNotKeepItsOldText() {
        store.add(Event(7, "formula"), "12+3")
        assertEquals("12+3", store.text("formula", 7))
        store.add(Event(7, "formula"), "")
        assertEquals("", store.text("formula", 7))
    }

    @Test fun onlyTheAskedWindowIsResolvedAndOnlyOnce() {
        store.add(Event(7, "formula"), "1")
        store.add(Event(9, "chat"), "hi")
        assertEquals("1", store.text("formula", 7))
        assertEquals(1, resolved)
        assertEquals("1", store.text("formula", 7))
        assertEquals(1, resolved)
        assertEquals("hi", store.text("chat", 9))
        assertEquals(2, resolved)
    }

    @Test fun anUnresolvableSourceIsSkipped() {
        store.add(Event(7, null), "lost")
        store.add(Event(7, "formula"), "2")
        assertEquals("2", store.text("formula", 7))
    }
}
