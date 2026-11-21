package io.github.ccch1mneyyy.dsh_app.text

import io.flutter.embedding.engine.systemchannels.ProcessTextChannel
import io.flutter.plugin.common.MethodChannel
import org.junit.Assert.*
import org.junit.Test

class CachedTextActionsTest {
    private class Engine : ProcessTextChannel.ProcessTextMethodHandler {
        var asked = 0
        var label = "翻译"
        val processed = mutableListOf<Triple<String, String, Boolean>>()

        override fun queryTextActions(): Map<String, String> {
            asked++
            return mapOf("translate" to label)
        }

        override fun processTextAction(id: String, text: String, readOnly: Boolean, result: MethodChannel.Result) {
            processed += Triple(id, text, readOnly)
            result.success("done")
        }
    }

    private class Result : MethodChannel.Result {
        var value: Any? = null

        override fun success(result: Any?) {
            value = result
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) = fail(errorCode)

        override fun notImplemented() = fail("notImplemented")
    }

    @Test fun theEngineIsAskedOnceUntilForgotten() {
        val engine = Engine()
        val cache = CachedTextActions(engine)
        repeat(20) { assertEquals(mapOf("translate" to "翻译"), cache.queryTextActions()) }
        assertEquals(1, engine.asked)

        engine.label = "Translate"
        cache.forget()
        assertEquals(mapOf("translate" to "Translate"), cache.queryTextActions())
        assertEquals(mapOf("translate" to "Translate"), cache.queryTextActions())
        assertEquals(2, engine.asked)
    }

    @Test fun runningAnActionIsTheEngines() {
        val engine = Engine()
        val cache = CachedTextActions(engine)
        val result = Result()
        cache.processTextAction("translate", "你好", true, result)
        assertEquals(listOf(Triple("translate", "你好", true)), engine.processed)
        assertEquals("done", result.value)
        assertEquals(0, engine.asked)
    }
}
