package io.github.ccch1mneyyy.dsh_app.phone.a11y

import io.github.ccch1mneyyy.dsh_app.phone.TargetInfo
import org.junit.Assert.*
import org.junit.Test

/**
 * A `type` whose read-back differs (the field cut or filtered what was typed): the result goes to
 * the model, so a password or code field never says what it holds, while an ordinary one keeps
 * its diagnostic.
 */
class ReadBackMismatchTest {
    /** The single input of a screen, as the driver hands it to the core and the gate. */
    private fun field(hint: String? = null, viewId: String? = null, password: Boolean = false): TargetInfo {
        val bounds = Box(0, 0, 400, 800)
        val node = UiNode(className = "android.widget.EditText", hint = hint, viewId = viewId,
            bounds = Box(0, 100, 300, 150), editable = true, password = password)
        val screen = ScreenFormat.format(ScreenInput("s1", "Example", "example.app", 400, 800, false,
            listOf(UiWindow(1, WindowKind.APP, "example.app", null, bounds, UiNode(bounds = bounds, children = listOf(node))))))
        val e = screen.elements.single()
        return TargetInfo("s1", e.id, e.role, e.label, e.packageName, "Example", e.password, e.secret, e.editable, e.viewId)
    }

    @Test fun aCodeOrPasswordFieldNeverSaysWhatItHolds() {
        for (target in listOf(field(hint = "验证码"), field(hint = "请输入短信校验码"), field(viewId = "app:id/et_pwd"), field(hint = "密码", password = true))) {
            val message = MainScreenDriver.readBackMismatch("13579", target)
            assertFalse(message, message.any(Char::isDigit))
            assertTrue(message, message.startsWith("已输入，但回读不一致"))
            assertTrue(message, message.contains("没有重试，也没有提交"))
        }
    }

    @Test fun anOrdinaryFieldStillSaysWhatItHolds() {
        val nickname = field(hint = "昵称")
        assertEquals(
            "已输入，但回读不一致：框里现在是「小明 123456」。没有重试，也没有提交；请看新屏幕决定下一步。",
            MainScreenDriver.readBackMismatch("小明 123456", nickname),
        )
        assertTrue(MainScreenDriver.readBackMismatch("", nickname).contains("框里现在是空"))
        assertTrue(MainScreenDriver.readBackMismatch("4111 1111 1111 1111", nickname).contains("«银行卡 ****1111»"))
    }

    @Test fun anUnknownReadBackDoesNotClaimAnyCurrentContent() {
        val message = MainScreenDriver.readBackMismatch(null, field(hint = "昵称"))
        assertTrue(message, message.contains("已输入"))
        assertTrue(message, message.contains("没有重试，也没有提交"))
        assertFalse(message, message.contains("框里现在是"))
        assertFalse(message, message.contains("空"))
        assertFalse(message, message.contains("回读一致"))
        assertTrue(message, message.contains("无法确认") || message.contains("未能确认"))
    }

    @Test fun aKnownEmptyReadBackStillReportsEmptyContent() {
        val message = MainScreenDriver.readBackMismatch("", field(hint = "昵称"))
        assertTrue(message, message.contains("已输入"))
        assertTrue(message, message.contains("框里现在是空"))
        assertTrue(message, message.contains("没有重试，也没有提交"))
    }

    /** vivo's calculator display reads "" while it shows what was typed: empty is "cannot see". */
    @Test fun anEmptyReadBackIsUnconfirmedNotAMismatch() {
        val note = typedNote("formula", ReadBackMatch.EMPTY)
        assertTrue(note, note.contains("已在「formula」输入"))
        assertTrue(note, note.contains("无法确认"))
        assertTrue(note, note.contains("不要重复输入"))
        assertFalse(note, note.contains("回读一致"))
        assertFalse(note, note.contains("不一致"))
        // The note comes before any submit, so it never claims one either way.
        assertFalse(note, note.contains("提交"))
        assertEquals("已在「formula」输入，回读一致。", typedNote("formula", ReadBackMatch.SAME))
    }

    @Test fun textThatWillBeSubmittedMustKeepItsSpacing() {
        assertEquals(ReadBackMatch.DIFFERENT, readBackMatch("newyork", "new york", ignoreSpaces = false))
        assertEquals(ReadBackMatch.DIFFERENT, readBackMatch("new  york", "new york", ignoreSpaces = false))
        assertEquals(ReadBackMatch.FORMATTED, readBackMatch("newyork", "new york", ignoreSpaces = true))
        // Display formatting and invisible marks still match when submitting.
        assertEquals(ReadBackMatch.FORMATTED, readBackMatch("１２×３", "12*3", ignoreSpaces = false))
        assertEquals(ReadBackMatch.FORMATTED, readBackMatch("\u200Enew york", "new york", ignoreSpaces = false))
        assertEquals(ReadBackMatch.FORMATTED, readBackMatch("new\u00A0york", "new york", ignoreSpaces = false))
        assertEquals(ReadBackMatch.EMPTY, readBackMatch("", "new york", ignoreSpaces = false))
    }

    @Test fun readBackMatchToleratesFormattingOnly() {
        assertEquals(ReadBackMatch.SAME, readBackMatch("12+30", "12+30"))
        assertEquals(ReadBackMatch.UNKNOWN, readBackMatch(null, "12+30"))
        assertEquals(ReadBackMatch.EMPTY, readBackMatch("", "12+30"))
        assertEquals(ReadBackMatch.SAME, readBackMatch("", ""))
        assertEquals(ReadBackMatch.FORMATTED, readBackMatch("138 0013 8000", "13800138000"))
        assertEquals(ReadBackMatch.FORMATTED, readBackMatch("12×3−4÷2", "12*3-4/2"))
        assertEquals(ReadBackMatch.FORMATTED, readBackMatch("１２＋３０", "12+30"))
        assertEquals(ReadBackMatch.FORMATTED, readBackMatch("\u200E12 + 30\u200E", "12+30"))
        assertEquals(ReadBackMatch.DIFFERENT, readBackMatch("12+3", "12+30"))
        assertEquals(ReadBackMatch.DIFFERENT, readBackMatch("小明", "小红"))
    }

    @Test fun anUnknownSecretReadBackDoesNotInventAnEmptyValue() {
        for (target in listOf(field(hint = "验证码"), field(hint = "密码", password = true))) {
            val message = MainScreenDriver.readBackMismatch(null, target)
            assertTrue(message, message.contains("已输入"))
            assertTrue(message, message.contains("没有重试，也没有提交"))
            assertFalse(message, message.contains("框里现在是"))
            assertFalse(message, message.contains("空"))
            assertFalse(message, message.contains("回读一致"))
            assertTrue(message, message.contains("无法确认") || message.contains("未能确认"))
        }
    }

    @Test fun freshSecretMetadataOverridesAnOrdinaryObservedTargetForOutput() {
        val ordinary = field(hint = "昵称")
        val value = "sample-value"
        val message = MainScreenDriver.readBackMismatch(value, ordinary, currentSecret = true)
        assertFalse(message, message.contains(value))
        assertFalse(message, message.contains("框里现在是"))
        assertTrue(message, message.contains("内容不回传"))
        assertTrue(message, message.contains("已输入，但回读不一致"))
        assertTrue(message, message.contains("没有重试，也没有提交"))
        val unknown = MainScreenDriver.readBackMismatch(null, ordinary, currentSecret = true)
        assertTrue(unknown, unknown.contains("未能确认"))
        assertFalse(unknown, unknown.contains("空"))
    }

}
