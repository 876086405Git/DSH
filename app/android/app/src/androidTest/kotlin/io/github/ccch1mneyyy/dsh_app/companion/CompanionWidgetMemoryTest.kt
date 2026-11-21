package io.github.ccch1mneyyy.dsh_app.companion

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import android.test.AndroidTestCase

/** Real preferences, isolated names: never edits the person's widget state. */
@Suppress("DEPRECATION")
class CompanionWidgetMemoryTest : AndroidTestCase() {
    private lateinit var isolated: Context
    private lateinit var prefs: SharedPreferences

    override fun setUp() {
        super.setUp()
        isolated = object : ContextWrapper(context) {
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
                baseContext.getSharedPreferences("memory_widget_test_$name", mode)
        }
        prefs = isolated.getSharedPreferences("companion_widget", Context.MODE_PRIVATE)
        assertTrue(prefs.edit().clear().commit())
    }

    override fun tearDown() {
        prefs.edit().clear().commit()
        super.tearDown()
    }

    fun testClearRemovesBothKeysAndPreservesTheOtherWidgetState() {
        assertTrue(CompanionWidgetProvider.store(isolated, mapOf(
            "name" to "她", "bond" to 2, "line" to "未被标注主题的旧回答", "saidAt" to 42L,
        )))
        assertTrue(CompanionWidgetProvider.store(isolated, mapOf(
            "memoryArchiveId" to "phone", "memoryControlRevision" to 1,
            "line" to null, "saidAt" to null,
        )))
        assertFalse(prefs.contains("line"))
        assertFalse(prefs.contains("saidAt"))
        assertEquals("她", prefs.getString("name", null))
        assertEquals(2L, prefs.getLong("bond", -1))
        assertEquals(1L, prefs.getLong("memoryControlRevision", -1))
    }

    fun testThePersistedFenceRejectsLateAndUnversionedWriters() {
        assertTrue(CompanionWidgetProvider.store(isolated, mapOf(
            "memoryArchiveId" to "phone", "memoryControlRevision" to 4,
            "line" to null, "saidAt" to null,
        )))
        assertFalse(CompanionWidgetProvider.store(isolated, mapOf(
            "memoryArchiveId" to "phone", "memoryControlRevision" to 3,
            "line" to "排队的旧回答", "saidAt" to 43L,
        )))
        assertFalse(CompanionWidgetProvider.store(isolated, mapOf("line" to "无版本旧写入", "saidAt" to 44L)))
        assertFalse(prefs.contains("line"))
        assertFalse(prefs.contains("saidAt"))
        assertTrue(CompanionWidgetProvider.store(isolated, mapOf(
            "memoryArchiveId" to "phone", "memoryControlRevision" to 4,
            "line" to "新一轮的话", "saidAt" to 45L,
        )))
        assertEquals("新一轮的话", prefs.getString("line", null))
        assertEquals(45L, prefs.getLong("saidAt", 0))
    }
}
