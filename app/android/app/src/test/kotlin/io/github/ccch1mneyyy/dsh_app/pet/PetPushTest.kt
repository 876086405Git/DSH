package io.github.ccch1mneyyy.dsh_app.pet

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PetPushTest {
    private val now = 1_729_850_000_000L

    @Test fun readsInterfaceMdPayload() {
        val p = PetPush.fromMap(
            mapOf(
                "state" to "working", "tier" to 2,
                "bubble" to mapOf(
                    "id" to "local:01JB|turn|1729", "kind" to "done", "text" to "修复登录重复提交 · 做完了", "title" to "修复登录重复提交",
                    "host" to """{"kind":"local","id":"local"}""", "sessionId" to "01JB", "untilMs" to now + 4_000,
                ),
                "sessionId" to "01JB", "host" to """{"kind":"local","id":"local"}""",
                "active" to true, "foreground" to false, "packId" to "deepy-whale", "size" to "large",
            ),
            now,
        )
        assertEquals("deepy-whale", p.packId)
        assertEquals("working", p.state)
        assertEquals(2, p.tier)
        assertEquals("01JB", p.sessionId)
        assertTrue(p.active)
        assertEquals("large", p.size)
        assertFalse(p.quiet)
        assertTrue(PetPush.fromMap(mapOf("quiet" to true), now).quiet)
        val b = p.bubble!!
        assertEquals("done", b.kind)
        assertEquals(now + 4_000, b.untilMs)
        assertEquals("修复登录重复提交 · 做完了", b.line)
        assertEquals("""{"kind":"local","id":"local"}""", b.host)
    }

    @Test fun readsTheTargetMapOfPetState() {
        val p = PetPush.fromMap(mapOf("target" to mapOf("host" to "h", "sessionId" to "s7"), "sessionId" to "ignored"), now)
        assertEquals("s7", p.sessionId)
        assertEquals("h", p.host)
    }

    @Test fun applicationReduceMotionIsOptionalAndExplicit() {
        assertFalse(PetPush.fromMap(emptyMap<String, Any>(), now).reduceMotion)
        assertTrue(PetPush.fromMap(mapOf("reduceMotion" to true), now).reduceMotion)
        assertFalse(PetPush.fromMap(mapOf("reduceMotion" to "true"), now).reduceMotion)
        assertFalse(PetPush.fromMap(mapOf("reduceMotion" to false), now).reduceMotion)
    }

    @Test fun noneMeansNoPet() {
        assertNull(PetPush.fromMap(mapOf("packId" to "none"), now).packId)
        assertNull(PetPush.fromMap(mapOf("packId" to "../evil"), now).packId)
        assertNull(PetPush.fromMap(mapOf("packId" to "Deepy"), now).packId)
        assertNull(PetPush.fromMap(emptyMap<String, Any>(), now).packId)
    }

    @Test fun malformedFieldsFallBackSafely() {
        val p = PetPush.fromMap(mapOf("state" to "dancing", "tier" to 99, "size" to "huge", "bubble" to mapOf("text" to "  ")), now)
        assertEquals("idle", p.state)
        assertEquals(9, p.tier)
        assertEquals("medium", p.size)
        assertNull(p.bubble)
        assertFalse(p.active)
    }

    @Test fun customSizeCarriesItsHeightInTheKey() {
        assertEquals("custom:45.0", PetPush.fromMap(mapOf("state" to "idle", "size" to "custom", "bodyHeight" to 45), now).size)
        assertEquals("custom:90.0", PetPush.fromMap(mapOf("state" to "idle", "size" to "custom", "bodyHeight" to 500.0), now).size)
        assertEquals("medium", PetPush.fromMap(mapOf("state" to "idle", "size" to "custom"), now).size)
        assertEquals("medium", PetPush.fromMap(mapOf("state" to "idle", "size" to "custom:45"), now).size)
        assertEquals(45f, PetSize.dpOf("custom:45.0"))
        assertEquals(40f, PetSize.dpOf("large"))
    }

    @Test fun theLineIsDartsTextVerbatim() {
        val b = PetPush.fromMap(mapOf("bubble" to mapOf("id" to "x", "text" to "3 个对话做完了", "title" to "修复登录", "untilMs" to now + 8_000)), now).bubble!!
        assertEquals("3 个对话做完了", b.line)
    }

    @Test fun bubbleTimesStayWithinAMinute() {
        val late = PetPush.fromMap(mapOf("bubble" to mapOf("text" to "出错了", "untilMs" to now + 10_000_000)), now).bubble!!
        assertEquals(now + 60_000, late.untilMs)
        val past = PetPush.fromMap(mapOf("bubble" to mapOf("text" to "出错了", "untilMs" to now - 5)), now).bubble!!
        assertEquals(now, past.untilMs)
        val none = PetPush.fromMap(mapOf("bubble" to mapOf("text" to "出错了")), now).bubble!!
        assertEquals(now + PetPush.DEFAULT_BUBBLE_MS, none.untilMs)
    }

    @Test fun activeFallsBackForOlderSenders() {
        assertTrue(PetPush.fromMap(mapOf("state" to "thinking"), now).active)
        assertTrue(PetPush.fromMap(mapOf("state" to "idle", "bubble" to mapOf("text" to "做完了")), now).active)
        assertFalse(PetPush.fromMap(mapOf("state" to "attention"), now).active)
        // Dart's own answer wins.
        assertFalse(PetPush.fromMap(mapOf("state" to "working", "active" to false), now).active)
    }

    @Test fun calmAndCallingSortTheStates() {
        for (s in listOf("idle", "sleeping", "roam")) assertTrue(s, PetPush.fromMap(mapOf("state" to s), now).calm)
        for (s in listOf("thinking", "working", "attention", "waking")) assertFalse(s, PetPush.fromMap(mapOf("state" to s), now).calm)
        for (s in listOf("attention", "error", "notification")) assertTrue(s, PetPush.fromMap(mapOf("state" to s), now).calling)
        assertFalse(PetPush.fromMap(mapOf("state" to "working"), now).calling)
    }

    @Test fun textIsFoldedAndCut() {
        assertEquals("做完了 修复", PetPush.clean("  做完了\n\t修复 ", 40))
        assertEquals("一二三四…", PetPush.clean("一二三四五六", 5))
        assertEquals("🐳🐳🐳🐳…", PetPush.clean("🐳".repeat(10), 5))
        assertNull(PetPush.clean(" \n ", 5))
    }
}
