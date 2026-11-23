package io.github.ccch1mneyyy.dsh_app.phone

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** What the island's card says DSH thinks: kept per conversation, the newest words, forgotten on request. */
class PhoneThoughtsTest {
    @After fun tearDown() {
        PhoneThoughts.listener = null
        PhoneThoughts.clear()
    }

    @Test fun keptPerConversationAndForgottenWithNull() {
        var heard = 0
        PhoneThoughts.listener = { heard++ }
        PhoneThoughts.set("a", "  打开微信  ")
        PhoneThoughts.set("b", "看一下设置")
        assertEquals("打开微信", PhoneThoughts.get("a"))
        assertEquals("看一下设置", PhoneThoughts.get("b"))
        assertNull(PhoneThoughts.get(null))
        // The same words again are no news.
        PhoneThoughts.set("a", "打开微信")
        assertEquals(2, heard)
        PhoneThoughts.set("a", null)
        assertNull(PhoneThoughts.get("a"))
        PhoneThoughts.set("b", " ")
        assertNull(PhoneThoughts.get("b"))
        assertEquals(4, heard)
    }

    @Test fun longWordsKeepTheirEnd() {
        PhoneThoughts.set("a", "甲".repeat(PhoneThoughts.MAX_CHARS) + "乙")
        val kept = PhoneThoughts.get("a")!!
        assertEquals(PhoneThoughts.MAX_CHARS, kept.length)
        assertEquals('乙', kept.last())
    }

    @Test fun onlyAHandfulOfConversationsAreKept() {
        for (i in 1..20) PhoneThoughts.set("s$i", "第 $i 个")
        // The newest always stays.
        assertEquals("第 20 个", PhoneThoughts.get("s20"))
        assertEquals(8, (1..20).count { PhoneThoughts.get("s$it") != null })
    }
}
