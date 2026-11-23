package io.github.ccch1mneyyy.dsh_app.phone.skills

import io.github.ccch1mneyyy.dsh_app.phone.Json
import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PhoneSkillStoreTest {
    @get:Rule val tmp = TemporaryFolder()
    private var now = 1000L
    private val root get() = File(tmp.root, "rootfs")
    private val privateDir get() = File(tmp.root, "native")
    private val home get() = File(root, "root/.dsh")
    private val from = PhoneSkillOrigin("session-fixture", 7)
    private val document = PhoneSkillDocument("phone-open-notes", "Open notes", "Find a note", "When reading a note",
        listOf("com.example.notes"), linkedMapOf("entry" to "Open the app.", "steps" to "1. Select notes.",
            "pitfalls" to "Check the account.", "success" to "The list is visible.", "handoff" to "Ask if unclear."), true)

    // The storage slice requires a validator. The drafting slice supplies the product policy.
    private fun store(clean: (PhoneSkillDocument) -> PhoneSkillDocument = { it }): PhoneSkillStore {
        home.mkdirs()
        return PhoneSkillStore(root, privateDir, clean, { it.replace("123456", "<parameter>") }) { now }
    }

    private fun install(s: PhoneSkillStore, d: PhoneSkillDocument = document) = s.accept(s.putDraft(d, from).id)
    private fun guest(name: String = document.name) = File(home, "skills/" + name + "/SKILL.md")
    private fun error(code: String, action: () -> Unit) {
        try { action(); fail("Expected " + code) } catch (e: PhoneSkillProblem) { assertEquals(code, e.code) }
    }

    @Test fun documentRoundTripsBothLanguagesAndRejectsDuplicateOrMissingSections() {
        for (english in listOf(true, false)) {
            val d = document.copy(english = english, description = "Find: #saved \"notes\"")
            val body = d.render("trial", "learned", from)
            assertEquals(d, PhoneSkillDocument.parseMarkdown(body))
            error("invalid") { PhoneSkillDocument.parseMarkdown(body.replace("name: ", "name: duplicate\nname: ")) }
            error("invalid") { PhoneSkillDocument.parseMarkdown(body.replace("## ", "# ")) }
        }
    }

    @Test fun draftsSurviveRestartAndOnlyKeepNewestTwentyLessThanThirtyDaysOld() {
        val s = store()
        for (letter in 'a'..'u') s.putDraft(document.copy(name = "phone-" + letter), from)
        val kept = store().list().drafts
        assertEquals(20, kept.size)
        assertEquals("phone-u", kept.first().document.name)
        assertFalse(kept.any { it.document.name == "phone-a" })
        assertFalse(guest().exists())
        now += 30L * 24 * 60 * 60 * 1000
        assertTrue(store().list().drafts.isEmpty())
        assertEquals("[]", File(privateDir, "drafts.json").readText())
    }

    @Test fun readAndEveryWriteUseManagedTextAndAnUnrelatedSkillIsNeverAdopted() {
        val s = store { d ->
            if (d.sections.values.any { "blocked" in it }) throw PhoneSkillProblem("sensitive", "Section")
            d.copy(display = d.display.replace("private-value", "<parameter>"))
        }
        val d = document.copy(display = "private-value")
        val pending = s.putDraft(d, from)
        assertFalse(File(privateDir, "drafts.json").readText().contains("private-value"))
        val installed = s.accept(pending.id)
        assertEquals("<parameter>", installed.document.display)
        assertEquals(installed.body, guest().readText())
        val header = PhoneSkillDocument.metadata(guest().readText())
        assertEquals("trial", header["state"])
        assertEquals("true", header["disable-model-invocation"])
        assertEquals("false", header["user-invocable"])
        val explicitEdit = d.sections + ("steps" to "1. Choose the saved list.")
        assertEquals(explicitEdit, s.save(d.name, sections = explicitEdit).document.sections)
        error("sensitive") { s.save(d.name, sections = explicitEdit + ("steps" to "blocked")) }
        val sidecar = File(guest().parentFile, ".state.json")
        sidecar.writeText("""{"state":"active","uses":1000}""")
        guest("phone-foreign").also { it.parentFile.mkdirs(); it.writeText("unmanaged") }
        val only = store().list().skills.single()
        assertEquals("trial", only.status.state)
        assertEquals(0L, only.status.uses)
        assertEquals(d.name, only.document.name)
        error("changed") { s.delete("phone-foreign") }
        assertEquals("unmanaged", guest("phone-foreign").readText())
    }

    @Test fun updatesCompareExactPublishedBytesAndDiffKeepsUnchangedLines() {
        val s = store()
        val old = install(s)
        val update = document.copy(sections = document.sections + ("entry" to "Choose default notes.") +
            ("success" to "Saved notes appear."))
        val pending = s.putDraft(update, from, old.targetSnapshot())
        val diff = pending.toMap()["diff"] as List<*>
        assertTrue(diff.contains(mapOf("op" to "-", "text" to "Open the app.")))
        assertTrue(diff.contains(mapOf("op" to "+", "text" to "Saved notes appear.")))
        assertTrue(diff.contains(mapOf("op" to " ", "text" to "Check the account.")))
        guest().appendText("\n")
        error("changed") { s.accept(pending.id) }
        assertEquals(old.body + "\n", guest().readText())
        assertEquals(pending.id, s.list().drafts.single().id)
        guest().writeText(old.body)
        assertEquals(update.sections, s.accept(pending.id).document.sections)
        assertTrue(store().list().drafts.isEmpty())
    }

    @Test fun updatingPendingCardRevokesOldCardAndPreservesItsOriginalFingerprint() {
        val s = store()
        val old = install(s)
        val first = s.putDraft(document.copy(display = "Updated"), from, old.targetSnapshot())
        val second = s.putDraft(document.copy(display = "Revised"), from, first.targetSnapshot())
        error("changed") { s.accept(first.id) }
        assertEquals(first.original, second.original)
        assertEquals(old.fingerprint, second.baseFingerprint)
        assertEquals("Revised", store().accept(second.id).document.display)
    }

    @Test fun archiveIsBoundedAndDeletedSkillCanRestoreWithoutAdoptingGuestArchives() {
        val s = store()
        install(s)
        for (letter in 'a'..'g') s.save(document.name, display = "Notes " + letter)
        val archive = File(home, "skills/.archive/" + document.name)
        assertEquals(5, archive.listFiles()!!.size)
        archive.listFiles()!!.maxBy { it.name }.writeText("foreign archive")
        assertEquals("Notes f", store().restore(document.name).document.display)
        s.delete(document.name)
        assertFalse(guest().exists())
        assertEquals(listOf(document.name), store().list().archived)
        assertEquals("Notes f", store().restore(document.name).document.display)
        assertTrue(archive.listFiles()!!.size <= 5)
    }

    @Test fun recentFiveAndLastThreeMissesDriveOnlyActualTransitions() {
        val s = store()
        val name = install(s).document.name
        assertEquals("promoted", s.record(name, "ok").change)
        for (o in listOf("miss", "void", "void", "void", "void", "void")) assertNull(s.record(name, o).change)
        val last = s.record(name, "miss")
        assertEquals("suspended", last.change)
        assertEquals(listOf("void", "void", "void", "void", "miss"), last.skill.status.recent)
        assertEquals(8L, last.skill.status.uses)
        assertTrue(guest().readText().contains("disable-model-invocation: true"))
        assertTrue(guest().readText().contains("user-invocable: false"))
        assertEquals(last.skill.status, s.record(name, "ok").skill.status)
        assertEquals("active", store().setEnabled(name, true).status.state)
        assertNull(s.record(name, "miss").change)
        assertEquals("suspended", s.record(name, "miss").change)
        assertFalse(guest().parentFile.resolve(".state.json").readText().contains("session-fixture"))
    }

    @Test fun suspensionReasonSurvivesRestartAndClearsOnReenable() {
        val s = store()
        val name = install(s).document.name
        s.setEnabled(name, false)
        assertEquals("manual", store().get(name).toMap()["suspensionReason"])

        val file = File(privateDir, "records/$name.json")
        val row = Json.parseStrict(file.readText()) as Map<*, *>
        val legacyStatus = (row["status"] as Map<*, *>).filterKeys { it != "suspensionReason" }
        file.writeText(Json.write(row + ("status" to legacyStatus)))
        assertNull(store().get(name).status.suspensionReason)

        s.setEnabled(name, true)
        s.record(name, "miss")
        s.record(name, "miss")
        assertEquals("misses", store().list().skills.single().toMap(false)["suspensionReason"])
        s.setEnabled(name, true)
        assertNull(store().get(name).status.suspensionReason)
    }

    @Test fun independentlyEditedMirrorCannotVetoManualOrAutomaticSuspension() {
        val s = store()
        val name = install(s).document.name
        guest().writeText("external bytes")
        assertEquals("suspended", s.setEnabled(name, false).status.state)
        assertEquals("trial", s.setEnabled(name, true).status.state)
        assertNull(s.record(name, "miss", document).change)
        assertEquals("suspended", s.record(name, "miss", document).change)
        assertEquals("external bytes", guest().readText())
        assertEquals("suspended", store().list().skills.single().status.state)
        assertTrue(File(guest().parentFile, ".state.json").readText().contains("\"state\":\"suspended\""))
    }

    @Test fun legacyCanOnlyBeListedAndDeletedWithoutFollowingSymlinksOrRemovingUnownedFiles() {
        val s = store()
        val early = "phone-task-" + "a".repeat(32)
        val md = guest(early)
        md.parentFile.mkdirs()
        md.writeText("legacy bytes 123456")
        val privateNote = File(md.parentFile, "user-note.txt").apply { writeText("keep") }
        assertEquals(early, s.list().legacy.single()["name"])
        assertEquals("legacy bytes 123456", md.readText())
        error("invalid") { s.save(early, display = "new") }
        error("invalid") { s.delete("../elsewhere") }
        val linked = "phone-task-" + "b".repeat(32)
        Files.createSymbolicLink(guest(linked).parentFile.toPath(), md.parentFile.toPath())
        error("invalid") { s.delete(linked) }
        s.delete(early)
        assertTrue(s.list().legacy.isEmpty())
        assertEquals("keep", privateNote.readText())
        assertFalse(md.exists())
        val archive = File(home, "skills/.archive/" + early).listFiles()!!.single().readText()
        assertTrue(archive.contains("legacy bytes <parameter>"))
        assertFalse(archive.contains("123456"))
        assertTrue(archive.contains("disable-model-invocation: true"))
    }

    @Test fun interruptedProjectionResumesAndInterruptedAcceptReceiptConsumesTheCard() {
        val s = store()
        install(s)
        val first = s.get(document.name)
        val draft = s.putDraft(document.copy(display = "Updated"), from, first.targetSnapshot())
        val archive = File(home, "skills/.archive")
        val outside = tmp.newFolder("outside")
        Files.createSymbolicLink(archive.toPath(), outside.toPath())
        error("invalid") { s.accept(draft.id) }
        assertTrue(outside.list()!!.isEmpty())
        Files.delete(archive.toPath())
        val restarted = store().list()
        assertEquals("Updated", restarted.skills.single().document.display)
        assertEquals(restarted.skills.single(), store().accept(draft.id))
        assertTrue(restarted.drafts.isEmpty())
        assertEquals(1, restarted.skills.single().history.size)
    }

    @Test fun interruptedPublicationConflictingWithExternalEditLeavesLastConfirmedSkillAccessible() {
        val s = store()
        val old = install(s)
        val archive = File(home, "skills/.archive")
        Files.createSymbolicLink(archive.toPath(), tmp.root.toPath())
        error("invalid") { s.save(document.name, display = "Changed") }
        Files.delete(archive.toPath())
        guest().writeText("independently edited")
        assertEquals(old.document, store().list().skills.single().document)
        assertEquals("independently edited", guest().readText())
        s.delete(document.name)
        assertFalse(guest().exists())
        val restored = s.restore(document.name)
        assertEquals(old.document, restored.document)
        assertEquals(old.body, guest().readText())
    }
}
