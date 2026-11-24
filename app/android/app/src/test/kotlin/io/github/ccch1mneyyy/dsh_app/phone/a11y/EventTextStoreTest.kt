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

    /** The clearing event fell out of the buffer before anyone read it: no stale "12+3". */
    @Test fun aDroppedClearingEventDoesNotLeaveOldText() {
        store.add(Event(7, "formula"), "12+3")
        assertEquals("12+3", store.text("formula", 7))
        store.add(Event(7, "formula"), "")
        repeat(32) { store.add(Event(9, "chat"), "x$it") }
        assertNull(store.text("formula", 7))
        assertEquals("x31", store.text("chat", 9))
    }

    /** A newer event dropped while an older one resolves: the older text is not committed. */
    @Test fun anOlderTextResolvedLateDoesNotWin() {
        lateinit var racing: EventTextStore<Event, String>
        var flooded = false
        racing = EventTextStore({ it.window }) { event ->
            // While "12+3" resolves, the field is cleared and that event is pushed out of the buffer.
            if (!flooded) {
                flooded = true
                racing.add(Event(7, "formula"), "")
                repeat(32) { racing.add(Event(9, "chat"), "x") }
            }
            event.source
        }
        racing.add(Event(7, "formula"), "12+3")
        assertNull(racing.text("formula", 7))
    }

    @Test fun anUnresolvableSourceIsSkipped() {
        store.add(Event(7, null), "lost")
        store.add(Event(7, "formula"), "2")
        assertEquals("2", store.text("formula", 7))
    }
}
