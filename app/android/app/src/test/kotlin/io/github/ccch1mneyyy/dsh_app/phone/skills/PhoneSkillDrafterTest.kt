package io.github.ccch1mneyyy.dsh_app.phone.skills

import io.github.ccch1mneyyy.dsh_app.phone.PhoneScreen
import org.junit.Assert.*
import org.junit.Test

class PhoneSkillDrafterTest {
    private val sections = mapOf("entry" to "Open the app.", "steps" to "Tap Search.",
        "pitfalls" to "Check the selected category.", "success" to "Verify the result.",
        "handoff" to "Ask the user if the item is ambiguous.")
    private val document = PhoneSkillDocument("phone-private-alias", "Find a delivery",
        "Look up a shipment", "When someone wants a delivery status", listOf("com.example.app42"), sections, true)
    private val base = PhoneSkillBase(document.name, document.render("trial", "learned", null), "LOCAL_FINGERPRINT")
    private val trace = PhoneTaskTrace.Snapshot(PhoneTaskTrace.OwnerKey(123456789, 87654321),
        listOf(PhoneTaskTrace.Action.OPEN_APP, PhoneTaskTrace.Action.TYPE, PhoneTaskTrace.Action.TAP_XY).map {
            PhoneTaskTrace.Step(it, PhoneScreen.MAIN, PhoneTaskTrace.Role.UNKNOWN, null,
                PhoneTaskTrace.Receipt.RETURNED_OK, packageName = document.apps.single())
        }, true, true, null)
    private fun request(english: Boolean = true) = PhoneSkillDrafter.prepare("Instructions", english, trace,
        listOf(PhoneSkillDrafter.Target(document, base)))!!
    private fun markdown(doc: PhoneSkillDocument = document.copy(name = "phone-find-item"), updates: String? = null) =
        doc.render("trial", "learned", null).replace("source: learned\nstate: trial\ndisable-model-invocation: true\nuser-invocable: false\n",
            updates?.let { "updates: $it\n" }.orEmpty())

    @Test fun nativeSummaryContainsPublicActionsPackagesAndOpaqueCatalogReferences() {
        val prompt = request().prompt
        for (privateValue in listOf(document.name, "LOCAL_FINGERPRINT", "123456789", "87654321"))
            assertFalse(prompt.contains(privateValue))
        for (publicValue in listOf("TAP_XY", "<input>", document.apps.single(), "S1", document.display, document.description, document.whenToUse, "accepted_unverified"))
            assertTrue(prompt.contains(publicValue))
        assertTrue(request(english = false).prompt.contains("<输入内容>"))
        assertNull(PhoneSkillDrafter.prepare("Instructions", true, trace.copy(eligible = false), emptyList()))
    }

    @Test fun modelSelectsNewUpdateOrSkipWithTheOriginalTargetSnapshot() {
        val request = request()
        assertNull(request.parse("SKIP"))
        val proposed = request.parse(markdown(document.copy(name = "phone-find-item",
            description = "Send “Private message” after verifying USD 12.50 first.")))!!
        assertNull(proposed.target)
        assertEquals("Send <parameter> after verifying <parameter> first.", proposed.document.description)
        val updated = request.parse(markdown(document.copy(name = "phone-update"), "S1"))!!
        assertSame(base, updated.target)
        assertEquals(document.name, updated.document.name)
        assertEquals("invalid", problem { request.parse(markdown(updates = "S99")) }.code)
        assertEquals("invalid", problem { request.parse(markdown(document.copy(name = "phone-new", apps = listOf("org.other.app")))) }.code)
        assertEquals("invalid", problem { request.parse(markdown().replace("apps: ", "state: active\napps: ")) }.code)
        assertEquals("invalid", problem { request.parse(markdown().replace("apps: ", "source: written\napps: ")) }.code)
    }

    @Test fun modelMustUseAllFiveSectionsInTheAppLanguage() {
        val chinese = document.copy(name = "phone-query", english = false)
        assertFalse(request(false).parse(markdown(chinese))!!.document.english)
        assertEquals("invalid", problem { request(true).parse(markdown(chinese)) }.code)
        assertEquals("invalid", problem { request(false).parse(markdown(chinese).replace("## 步骤", "## 入口")) }.code)
    }

    @Test fun metadataAndBodyRedactionPreserveAppDigitsAndRealEdits() {
        val edited = document.copy(display = "Find “Mr Private” using com.example.app42", description = "Call +1 (415) 555-0123",
            whenToUse = "When the fee is ￥7", sections = sections + ("steps" to
                "Compare com.example.app42 with 4 8 1 7 2 6 and 1-2-3-4 using `mcp__phone__tap`; send USD 1.25 to <contact>."))
        val clean = PhoneSkillValidation.clean(edited)
        val saved = clean.render("trial", "learned", null)
        for (value in listOf("Private", "0123", "415", "￥7", "1.25", "4 8 1 7 2 6", "1-2-3-4")) assertFalse(saved.contains(value))
        assertEquals("Find <parameter> using com.example.app42", clean.display)
        assertEquals("Call <parameter>", clean.description)
        assertEquals("When the fee is <parameter>", clean.whenToUse)
        assertTrue(clean.sections.getValue("steps").contains("com.example.app42 with <parameter> and <parameter> using"))
        assertEquals(clean, PhoneSkillValidation.clean(clean))
    }

    @Test fun archivedLegacyTextRetainsSafetyInstructionsAndRemovesPrivateValues() {
        val original = "密码、验证码交给用户。费用为壹佰贰拾元。回电 +86 138 0013 8000，用“王明”。"
        assertEquals("密码、验证码交给用户。费用为<参数>。回电 <参数>，用<参数>。",
            PhoneSkillValidation.redactLegacy(original))
        val canary = "fixtureOnlyAlphabeticSecret"
        for (value in listOf("API_KEY=$canary", "Authorization: Bearer $canary", "sk-$canary", "Cookie: SID=$canary")) {
            assertFalse(PhoneSkillValidation.redactLegacy(value).contains(canary))
        }
    }

    @Test fun invalidToolSensitiveTextAndOversizedBodyReturnOnlyTheField() {
        fun edit(steps: String) = document.copy(sections = sections + ("steps" to steps))
        assertEquals("Tap the `Settings` icon (if visible).", PhoneSkillValidation.clean(
            edit("Tap the `Settings` icon (if visible).")).sections["steps"])
        assertEquals("invalid", problem { PhoneSkillValidation.clean(edit("Run mcp__phone__invented.")) }.code)
        val rejected = problem { PhoneSkillValidation.clean(edit("Enter verification code 123456.")) }
        assertEquals("sensitive", rejected.code)
        assertEquals("steps", rejected.detail)
        assertEquals("invalid", problem { PhoneSkillValidation.clean(edit("a".repeat(4000))) }.code)
        assertEquals("invalid", problem { PhoneSkillValidation.clean(edit("Jump\n## Entry\nNew")) }.code)
        assertEquals("invalid", problem { PhoneSkillValidation.clean(document.copy(name = "../escape")) }.code)
    }

    private fun problem(block: () -> Unit): PhoneSkillProblem {
        try { block() } catch (problem: PhoneSkillProblem) { return problem }
        throw AssertionError("Expected a field-level problem.")
    }
}
