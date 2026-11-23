package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeFalse
import org.junit.Test

/** 「重置运行环境」 keeping chosen parts of /root: [retireRuntime], [settleReset], [restoreKept]. */
class RuntimeResetKeepTest {
    private val files: File = Files.createTempDirectory("reset-keep").toFile()
    private val base = File(files, "runtime")
    private val retired = File(files, "runtime.reset")
    private val keep = File(files, "runtime-keep")
    private val locked = mutableListOf<File>()

    @After fun cleanUp() {
        locked.forEach { it.setWritable(true) }
        files.deleteRecursively()
    }

    private val ui = ResetKeep.UI_AND_SKILLS.paths
    private val plugins = ResetKeep.PLUGINS_AND_SETTINGS.paths

    private fun write(root: File, vararg paths: String) {
        for (path in paths) File(root, path).apply { parentFile!!.mkdirs() }.writeText(path.substringAfterLast('/'))
    }

    private fun text(path: String): String? = File(base, "rootfs/$path").takeIf { it.isFile }?.readText()

    /** A used runtime: the user's /root with something in each kind of place. */
    private fun installed() {
        write(
            base,
            "rootfs/bin/sh",
            "rootfs/root/.dsh/dsh-go/ui.json",
            "rootfs/root/.dsh/skills/mine/SKILL.md",
            "rootfs/root/.agents/skills/shared/SKILL.md",
            "rootfs/root/.dsh/profiles/web/package.json",
            "rootfs/root/.dsh/cordis.patch.yml",
            "rootfs/root/.dsh/.env",
            "rootfs/root/.dsh/sessions/s1.jsonl",
            "rootfs/root/.dsh/.credentials.yaml",
            "rootfs/root/workspace/notes",
            "logs/dsh.log",
        )
        File(base, "rootfs.version").writeText("r1")
    }

    /** The completed PRoot .98 link/linkat layout, before the runtime is moved. */
    private fun prootLinks(first: String, vararg others: String): File {
        val root = File(base, "rootfs").canonicalFile
        val original = File(root, first)
        val store = File(root, "root/.l2s").apply { mkdirs() }
        val intermediate = File(store, ".l2s.${original.name}0001").toPath()
        val stored = File(store, "${intermediate.fileName}.%04d".format(others.size + 1))
        Files.move(original.toPath(), stored.toPath())
        Files.createSymbolicLink(intermediate, stored.toPath())
        for (name in listOf(first) + others) {
            val file = File(root, name).apply { parentFile!!.mkdirs() }
            Files.createSymbolicLink(file.toPath(), intermediate)
        }
        return stored
    }

    /** What install() does after a reset: extract staging, settle, activate with the restore. */
    private fun install(version: String = "r1", dropKept: Boolean = false) {
        settleReset(base, retired, keep, dropKept, sync = {})
        write(base, "staging/bin/sh", "staging/etc/os-release")
        File(base, "staging/root/.dsh").mkdirs()
        activateRootfs(base, version, keep, dropKept, sync = {})
    }

    private fun assertKeepFailed(block: () -> Unit) {
        try {
            block()
            fail("expected KeepFailed")
        } catch (e: KeepFailed) {
            assertTrue(e.message, e.message!!.startsWith("keep: "))
        }
    }

    /** Makes [dir] refuse renames into and out of it (skipped where permissions don't bind, as root). */
    private fun lock(dir: File) {
        dir.mkdirs()
        assertTrue(dir.setWritable(false))
        locked += dir
        assumeFalse("permissions are not enforced", dir.canWrite())
    }

    private fun assertSettled() {
        assertFalse("runtime.reset", retired.exists())
        assertFalse("runtime-keep", keep.exists())
        assertFalse("keep.trash", File(base, "keep.trash").exists())
        assertEquals("r1", File(base, "rootfs.version").readText())
    }

    private fun assertUserDataGone() {
        for (gone in listOf("root/.dsh/sessions/s1.jsonl", "root/.dsh/.credentials.yaml", "root/workspace/notes")) {
            assertNull(gone, text(gone))
        }
        assertTrue(File(base, "rootfs/root/workspace").isDirectory)
    }

    @Test fun resetUsesTheSameKeepChoiceForPrivateSkillAuthorityAndGuestDocuments() {
        installed()
        val privateRecord = File(files, "phone-skills/drafts.json")
        privateRecord.parentFile.mkdirs()
        privateRecord.writeText("private fixture")
        retireRuntime(base, retired, keep, ui)
        assertTrue(privateRecord.isFile)
        // A second explicit reset can discard a prior keep before the next installation.
        retireRuntime(base, retired, keep, emptyList())
        assertFalse(privateRecord.exists())
    }

    @Test fun keepsUiAndSkillsThroughResetAndInstall() {
        installed()
        retireRuntime(base, retired, keep, ui)
        assertFalse(base.exists())
        assertFalse(retired.exists())
        assertEquals("ui.json", File(keep, "root/.dsh/dsh-go/ui.json").readText())
        assertFalse(File(keep, "root/.dsh/profiles").exists())

        install()
        assertSettled()
        assertEquals("ui.json", text("root/.dsh/dsh-go/ui.json"))
        assertEquals("SKILL.md", text("root/.dsh/skills/mine/SKILL.md"))
        assertEquals("SKILL.md", text("root/.agents/skills/shared/SKILL.md"))
        for (gone in listOf("root/.dsh/profiles/web/package.json", "root/.dsh/cordis.patch.yml", "root/.dsh/.env")) {
            assertNull(gone, text(gone))
        }
        assertUserDataGone()
        assertEquals("os-release", text("etc/os-release"))
    }

    @Test fun keepsPluginsAndSettingsToo() {
        installed()
        retireRuntime(base, retired, keep, ui + plugins)
        install()
        assertSettled()
        for (path in listOf("root/.dsh/dsh-go/ui.json", "root/.dsh/profiles/web/package.json", "root/.dsh/cordis.patch.yml", "root/.dsh/.env")) {
            assertNotNull(path, text(path))
        }
        assertUserDataGone()
    }

    @Test fun keptSkillsMaterializeProotNamesAcrossSelectedAndDiscardedPaths() {
        installed()
        val names = listOf(
            "root/.dsh/skills/mine/SKILL.md",
            "root/.dsh/skills/mine/SKILL-backup.md",
            "root/.agents/skills/linked/SKILL.md",
        )
        prootLinks(names[0], names[1], names[2], "root/workspace/skill-copy")
        val outside = File(files, "ordinary-target").apply { writeText("ordinary") }
        val ordinary = "root/.dsh/skills/ordinary-link"
        Files.createSymbolicLink(File(base, "rootfs/$ordinary").toPath(), outside.toPath())

        retireRuntime(base, retired, keep, ui, sync = {})

        assertFalse(retired.exists())
        for (name in names) {
            assertTrue(name, Files.isRegularFile(File(keep, name).toPath(), LinkOption.NOFOLLOW_LINKS))
            assertEquals("SKILL.md", File(keep, name).readText())
        }
        assertEquals(outside.toPath(), Files.readSymbolicLink(File(keep, ordinary).toPath()))
        install()
        assertSettled()
        for (name in names) assertEquals("SKILL.md", text(name))
        assertEquals("ordinary", text(ordinary))
        assertFalse(File(base, "rootfs/root/.l2s").exists())
        assertNull(text("root/workspace/skill-copy"))
    }

    @Test fun selectedPluginDirectoryAndSingleFileSettingsKeepProotContent() {
        installed()
        prootLinks("root/.dsh/profiles/web/package.json", "root/workspace/package-copy")
        prootLinks("root/.dsh/.env", "root/workspace/env-copy")

        retireRuntime(base, retired, keep, plugins, sync = {})
        install()

        assertSettled()
        for (name in listOf("root/.dsh/profiles/web/package.json", "root/.dsh/.env")) {
            assertTrue(name, Files.isRegularFile(File(base, "rootfs/$name").toPath(), LinkOption.NOFOLLOW_LINKS))
            assertEquals(name.substringAfterLast('/'), text(name))
        }
        assertNull(text("root/.dsh/skills/mine/SKILL.md"))
    }

    @Test fun resumedProotKeepDoesNotReplaceAnAlreadyKeptItem() {
        installed()
        prootLinks("root/.dsh/skills/mine/SKILL.md", "root/.agents/skills/linked/SKILL.md")
        File(base, "reset.keep").writeText(ui.joinToString("\n"))
        assertTrue(base.renameTo(retired))
        val previous = File(keep, "root/.dsh/skills/mine/SKILL.md").apply { parentFile!!.mkdirs() }
        previous.writeText("earlier kept")

        settleReset(base, retired, keep, sync = {})
        install()

        assertSettled()
        assertEquals("earlier kept", text("root/.dsh/skills/mine/SKILL.md"))
        assertEquals("SKILL.md", text("root/.agents/skills/linked/SKILL.md"))
    }

    @Test fun aProotCopyFlushFailureRetainsTheStoreUntilInstallRetries() {
        installed()
        val name = "root/.dsh/skills/mine/SKILL.md"
        val stored = prootLinks(name, "root/.dsh/skills/mine/backup")

        assertKeepFailed {
            retireRuntime(base, retired, keep, ui, sync = { throw java.io.IOException("flush interrupted") })
        }

        assertFalse(base.exists())
        assertTrue(File(retired, "reset.keep").isFile)
        assertTrue(Files.isSymbolicLink(File(retired, "rootfs/$name").toPath()))
        assertEquals("SKILL.md", File(retired, "rootfs/root/.l2s/${stored.name}").readText())
        assertFalse(File(keep, "root/.dsh/skills").exists())
        install()
        assertSettled()
        assertEquals("SKILL.md", text(name))
        assertEquals("SKILL.md", text("root/.dsh/skills/mine/backup"))
    }

    @Test fun anUnresolvedProotChainKeepsTheRetiredStoreUntilExplicitDrop() {
        installed()
        val ordinary = "root/.dsh/skills/mine/notes.txt"
        write(base, "rootfs/$ordinary")
        val stored = prootLinks("root/.dsh/skills/mine/SKILL.md", "root/workspace/skill-copy")
        // PRoot decrements the count by moving the stored file before updating its intermediate.
        val next = File(stored.parentFile, stored.name.dropLast(4) + "0001")
        Files.move(stored.toPath(), next.toPath())

        assertKeepFailed { retireRuntime(base, retired, keep, ui, sync = {}) }
        assertEquals("SKILL.md", File(retired, "rootfs/root/.l2s/${next.name}").readText())
        assertFalse(File(keep, "root/.dsh/skills").exists())
        assertKeepFailed { settleReset(base, retired, keep, sync = {}) }

        settleReset(base, retired, keep, dropFailed = true, sync = {})
        install()
        assertSettled()
        assertEquals("notes.txt", text(ordinary))
        assertTrue(Files.isSymbolicLink(File(base, "rootfs/root/.dsh/skills/mine/SKILL.md").toPath()))
        assertNull(text("root/.dsh/skills/mine/SKILL.md"))
        assertEquals("SKILL.md", text("root/.agents/skills/shared/SKILL.md"))
        assertEquals("ui.json", text("root/.dsh/dsh-go/ui.json"))
    }

    @Test fun anAlreadyMissingProotFirstHopDoesNotBlockAnotherKeepReset() {
        for (withNewStore in listOf(false, true)) {
            files.listFiles()!!.forEach { it.deleteRecursively() }
            installed()
            val missing = "root/.dsh/skills/mine/SKILL.md"
            val ordinary = "root/.dsh/skills/mine/notes.txt"
            val readable = "root/.dsh/skills/mine/readable.md"
            write(base, "rootfs/$ordinary")
            prootLinks(missing, "root/workspace/old-copy")
            // Replay the old reset's relevant moves: keep the names, delete their
            // shared store with the retired runtime, then restore the same names.
            val selected = File(base, "rootfs/root/.dsh/skills")
            val oldKeep = File(files, "old-kept-skills")
            assertTrue(selected.renameTo(oldKeep))
            assertTrue(File(base, "rootfs/root/.l2s").deleteRecursively())
            assertTrue(oldKeep.renameTo(selected))
            if (withNewStore) {
                write(base, "rootfs/$readable")
                prootLinks(readable, "root/workspace/new-copy")
            }
            val firstHop = Files.readSymbolicLink(File(base, "rootfs/$missing").toPath())
            assertTrue(Files.notExists(firstHop, LinkOption.NOFOLLOW_LINKS))

            retireRuntime(base, retired, keep, ui, sync = {})
            install()

            assertSettled()
            assertEquals("notes.txt", text(ordinary))
            assertTrue(Files.isSymbolicLink(File(base, "rootfs/$missing").toPath()))
            assertNull(text(missing))
            if (withNewStore) {
                assertTrue(Files.isRegularFile(File(base, "rootfs/$readable").toPath(), LinkOption.NOFOLLOW_LINKS))
                assertEquals("readable.md", text(readable))
            }
        }
    }

    @Test fun keepingNothingDeletesEverything() {
        installed()
        prootLinks("root/.dsh/skills/mine/SKILL.md", "root/.dsh/skills/mine/backup")
        retireRuntime(base, retired, keep, emptyList(), sync = { throw AssertionError("no copies when keeping nothing") })
        assertFalse(base.exists())
        assertFalse(retired.exists())
        assertFalse(keep.exists())
        install()
        assertSettled()
        for (gone in ResetKeep.ALL) assertFalse(gone, File(base, "rootfs/$gone").exists())
    }

    @Test fun keptCopiesReplaceFreshOnes() {
        installed()
        retireRuntime(base, retired, keep, ui)
        settleReset(base, retired, keep)
        File(base, "staging/root/.dsh/skills/shipped").mkdirs()
        File(base, "staging/root/.dsh/skills/shipped/SKILL.md").writeText("fresh")
        activateRootfs(base, "r1", keep, sync = {})
        assertSettled()
        assertEquals("SKILL.md", text("root/.dsh/skills/mine/SKILL.md"))
        assertNull(text("root/.dsh/skills/shipped/SKILL.md"))
    }

    @Test fun symlinksMoveAsLinksAndAreNotFollowedWhenDeleting() {
        installed()
        val outside = File(files, "outside").apply { mkdirs() }
        File(outside, "precious").writeText("precious")
        Files.createSymbolicLink(File(base, "rootfs/root/workspace/link").toPath(), outside.toPath())
        Files.createSymbolicLink(File(base, "rootfs/root/.dsh/skills/linked").toPath(), outside.toPath())
        retireRuntime(base, retired, keep, ui)
        assertEquals("precious", File(outside, "precious").readText())
        install()
        val linked = File(base, "rootfs/root/.dsh/skills/linked")
        assertTrue(Files.isSymbolicLink(linked.toPath()))
        assertEquals("precious", File(linked, "precious").readText())
    }

    @Test fun aResetKilledAfterRetiringIsFinishedByTheNextInstall() {
        installed()
        File(base, "reset.keep").writeText(ui.joinToString("\n"))
        assertTrue(base.renameTo(retired)) // killed right here
        install()
        assertSettled()
        assertEquals("ui.json", text("root/.dsh/dsh-go/ui.json"))
        assertNull(text("root/.dsh/profiles/web/package.json"))
    }

    @Test fun aResetKilledWhileMovingResumesWhereItStopped() {
        installed()
        File(base, "reset.keep").writeText(ui.joinToString("\n"))
        assertTrue(base.renameTo(retired))
        File(keep, "root/.dsh").mkdirs()
        assertTrue(File(retired, "rootfs/root/.dsh/dsh-go").renameTo(File(keep, "root/.dsh/dsh-go"))) // killed here
        retireRuntime(base, retired, keep, ui) // the next reset (no runtime left) finishes it
        assertFalse(retired.exists())
        install()
        assertSettled()
        assertEquals("ui.json", text("root/.dsh/dsh-go/ui.json"))
        assertEquals("SKILL.md", text("root/.dsh/skills/mine/SKILL.md"))
    }

    @Test fun aFailedMoveKeepsTheRetiredRuntimeUntilItCanFinish() {
        installed()
        lock(File(keep, "root/.agents")) // the shared skills cannot move in
        assertKeepFailed { retireRuntime(base, retired, keep, ui) }
        assertFalse(base.exists()) // runtime reads as not installed
        assertEquals("SKILL.md", File(retired, "rootfs/root/.agents/skills/shared/SKILL.md").readText())
        assertEquals("ui.json", File(keep, "root/.dsh/dsh-go/ui.json").readText())

        // Still failing: the install stops before touching anything.
        assertKeepFailed { install() }
        assertFalse(File(base, "rootfs.version").exists())
        assertTrue(retired.exists())

        File(keep, "root/.agents").setWritable(true)
        install()
        assertSettled()
        assertEquals("SKILL.md", text("root/.agents/skills/shared/SKILL.md"))
        assertEquals("ui.json", text("root/.dsh/dsh-go/ui.json"))
    }

    @Test fun aFailedRestorePutsTheFreshCopyBackAndKeepsTheRest() {
        installed()
        retireRuntime(base, retired, keep, ui)
        lock(File(keep, "root/.agents")) // the shared skills cannot move out
        write(base, "staging/root/.agents/skills/shipped/SKILL.md")
        assertKeepFailed { activateRootfs(base, "r1", keep, sync = {}) }
        // Not installed, nothing lost: what moved is in place, the rest still kept, the fresh copy back.
        assertFalse(File(base, "rootfs.version").exists())
        assertEquals("ui.json", text("root/.dsh/dsh-go/ui.json"))
        assertEquals("SKILL.md", File(keep, "root/.agents/skills/shared/SKILL.md").readText())
        assertEquals("SKILL.md", text("root/.agents/skills/shipped/SKILL.md"))

        // The retry extracts again; the user's home (with what was restored) carries over.
        File(keep, "root/.agents").setWritable(true)
        install()
        assertSettled()
        assertEquals("ui.json", text("root/.dsh/dsh-go/ui.json"))
        assertEquals("SKILL.md", text("root/.agents/skills/shared/SKILL.md"))
        assertNull(text("root/.agents/skills/shipped/SKILL.md"))
    }

    @Test fun aRestoreThatCannotFinishIsDroppedOnRequest() {
        installed()
        retireRuntime(base, retired, keep, ui)
        lock(File(keep, "root/.agents")) // the shared skills cannot move out
        write(base, "staging/root/.agents/skills/shipped/SKILL.md")
        assertKeepFailed { activateRootfs(base, "r1", keep, sync = {}) }
        write(files, "runtime-keep.dropped/root/old") // left by an earlier drop cut short

        // 「不保留，继续安装」: what can move goes back, the rest is given up, the install finishes.
        install(dropKept = true)
        assertSettled()
        assertFalse(File(files, "runtime-keep.dropped").exists())
        assertEquals("ui.json", text("root/.dsh/dsh-go/ui.json"))
        assertEquals("SKILL.md", text("root/.dsh/skills/mine/SKILL.md"))
        assertNull(text("root/.agents/skills/shared/SKILL.md"))
        assertEquals("SKILL.md", text("root/.agents/skills/shipped/SKILL.md"))
    }

    @Test fun aKeepThatCannotMoveOutIsDroppedOnRequest() {
        installed()
        lock(File(keep, "root/.agents"))
        assertKeepFailed { retireRuntime(base, retired, keep, ui) }
        assertTrue(retired.exists())

        install(dropKept = true)
        assertSettled()
        assertEquals("ui.json", text("root/.dsh/dsh-go/ui.json"))
        assertEquals("SKILL.md", text("root/.dsh/skills/mine/SKILL.md"))
        assertNull(text("root/.agents/skills/shared/SKILL.md"))
    }

    @Test fun droppingWithNothingStuckRestoresEverything() {
        installed()
        retireRuntime(base, retired, keep, ui + plugins)
        install(dropKept = true)
        assertSettled()
        for (path in listOf("root/.dsh/dsh-go/ui.json", "root/.agents/skills/shared/SKILL.md", "root/.dsh/.env")) {
            assertNotNull(path, text(path))
        }
    }

    @Test fun aRetiredRuntimeWhoseDeleteWasCutShortKeepsNothingMore() {
        installed()
        retireRuntime(base, retired, keep, ui)
        install()
        // A settle that moved everything and lost its list, then was killed mid-delete.
        write(retired, "rootfs/root/.dsh/dsh-go/ui.json")
        settleReset(base, retired, keep)
        assertFalse(retired.exists())
        assertFalse(keep.exists())
    }

    @Test fun aRestoreKilledHalfwayIsFinishedByTheReinstall() {
        installed()
        retireRuntime(base, retired, keep, ui + plugins)
        write(base, "staging/bin/sh")
        File(base, "staging/root/.dsh").mkdirs()
        assertTrue(File(base, "staging").renameTo(File(base, "rootfs")))
        // Killed after two paths were back and one fresh copy was set aside.
        assertTrue(File(keep, "root/.dsh/dsh-go").renameTo(File(base, "rootfs/root/.dsh/dsh-go")))
        assertTrue(File(keep, "root/.dsh/skills").renameTo(File(base, "rootfs/root/.dsh/skills")))
        write(base, "keep.trash/root/.agents/skills/shipped/SKILL.md")

        install()
        assertSettled()
        for (path in listOf(
            "root/.dsh/dsh-go/ui.json", "root/.dsh/skills/mine/SKILL.md", "root/.agents/skills/shared/SKILL.md",
            "root/.dsh/profiles/web/package.json", "root/.dsh/cordis.patch.yml", "root/.dsh/.env",
        )) assertNotNull(path, text(path))
    }

    @Test fun theLatestResetDecidesWhatAnUnrestoredKeepHolds() {
        installed()
        retireRuntime(base, retired, keep, ui + plugins)
        // The install never ran; a fresh runtime got there some other way and is reset again.
        write(base, "rootfs/root/.dsh/dsh-go/ui.json")
        File(base, "rootfs/root/.dsh/dsh-go/ui.json").writeText("fresh")
        retireRuntime(base, retired, keep, ui)
        assertEquals("ui.json", File(keep, "root/.dsh/dsh-go/ui.json").readText())
        assertFalse(File(keep, "root/.dsh/profiles").exists())
        assertFalse(File(keep, "root/.dsh/.env").exists())

        retireRuntime(base, retired, keep, emptyList())
        assertFalse(keep.exists())
    }

    @Test fun aKeepListOnlyNamesKnownPaths() {
        installed()
        write(base, "rootfs/etc/passwd")
        File(base, "reset.keep").writeText("../../outside\nroot\netc/passwd\n root/.dsh/dsh-go \n")
        assertTrue(base.renameTo(retired))
        settleReset(base, retired, keep)
        assertFalse(retired.exists())
        assertEquals(listOf("dsh-go"), File(keep, "root/.dsh").list()!!.toList())
    }

    @Test fun anUnreadableKeepListTakesNothingAndDropsNothing() {
        installed()
        retireRuntime(base, retired, keep, ui)
        installed()
        assertTrue(base.renameTo(retired)) // no list, as from an older build
        settleReset(base, retired, keep)
        assertFalse(retired.exists())
        assertEquals("ui.json", File(keep, "root/.dsh/dsh-go/ui.json").readText())
        assertFalse(File(keep, "root/.dsh/profiles").exists())
    }

    @Test fun anUpgradeWithoutAKeepLeavesTheHomeAlone() {
        installed()
        write(base, "staging/bin/sh")
        activateRootfs(base, "r2", keep, sync = {})
        assertEquals("ui.json", text("root/.dsh/dsh-go/ui.json"))
        assertEquals("notes", text("root/workspace/notes"))
        assertEquals("r2", File(base, "rootfs.version").readText())
    }

    @Test fun wireNames() {
        assertEquals(setOf(ResetKeep.UI_AND_SKILLS), ResetKeep.fromWire(listOf("uiAndSkills", "bogus")))
        assertEquals(ResetKeep.entries.toSet(), ResetKeep.fromWire(listOf("pluginsAndSettings", "uiAndSkills")))
        assertTrue(ResetKeep.fromWire(emptyList()).isEmpty())
        // No kept path lies inside another (a restore moves each one on its own).
        for (a in ResetKeep.ALL) for (b in ResetKeep.ALL) if (a != b) assertFalse("$a in $b", a.startsWith("$b/"))
    }
}
