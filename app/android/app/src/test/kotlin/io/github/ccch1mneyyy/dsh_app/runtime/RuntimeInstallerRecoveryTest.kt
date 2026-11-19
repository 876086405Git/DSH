package io.github.ccch1mneyyy.dsh_app.runtime

import android.content.ContextWrapper
import java.io.File
import java.io.IOException
import java.nio.file.Files
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

class RuntimeInstallerRecoveryTest {
    private val files = Files.createTempDirectory("installer-recovery").toFile()
    private val base = File(files, "runtime")
    private val directories = setOf("opt/dsh", "opt/node", "opt/dsh-go", "etc/dsh-app", "usr/local/lib/node_modules/pnpm")
    private val spec = EngineUpgradeSpec("a".repeat(64), "24.04.5", ENGINE_PATHS)
    private class SpaceCheckReached : AssertionError("archive-space reservation reached")
    private val spaceCheck = SpaceCheckReached()
    // Observe the real installer's archive reservation without pretending to fill a disk.
    private val spaceFiles = object : File(files.path) {
        override fun getUsableSpace(): Long = throw spaceCheck
    }
    private val context = object : ContextWrapper(null) {
        override fun getFilesDir(): File = spaceFiles
    }

    @After fun cleanup() { files.deleteRecursively() }

    private fun write(path: String, text: String) {
        val file = File(base, path)
        file.parentFile!!.mkdirs()
        file.writeText(text)
    }

    private fun tree(name: String, version: String) {
        for (path in ENGINE_PATHS) {
            write("$name/$path" + if (path in directories) "/version" else "", version)
        }
    }

    private fun installed(version: String) {
        base.deleteRecursively()
        tree("rootfs", version)
        write("rootfs.version", version)
        write("rootfs/root/workspace/notes.txt", "user notes")
    }

    private fun interruptUpgrade(version: String, step: String) {
        tree("staging", version)
        val interrupted = IOException("interrupted at $step")
        assertSame(interrupted, assertThrows(IOException::class.java) {
            EngineUpgrade(base, sync = {}, afterStep = { if (it == step) throw interrupted })
                .activate(version, spec)
        })
    }

    private fun installer(version: String) = RuntimeInstaller(context, RuntimeManifest(
        runtimeVersion = version, abi = "arm64-v8a",
        archives = listOf(RuntimeArchive("engine-arm64-v8a.tar.xz", 1, null, 1024)),
        dshVersion = "0.2.2-rc.1", nodeVersion = "24.22.1",
        launchArgv = emptyList(), launchEnv = emptyMap(), raw = JSONObject(),
    ), onLog = {}, sync = {})

    private fun expectArchiveReservation(version: String) {
        assertSame(spaceCheck, assertThrows(SpaceCheckReached::class.java) {
            installer(version).install { _, _ -> }
        })
    }

    @Test fun aPublishedJournalForThisApkFinishesWithoutReservingAnotherArchive() {
        for (step in listOf("journal", "marker")) {
            installed("old")
            interruptUpgrade("new", step)
            val installer = installer("new")
            assertFalse(installer.isCurrent())
            installer.install { _, _ -> }
            assertTrue(installer.isCurrent())
            assertEquals("new", File(base, "rootfs/opt/dsh/version").readText())
            assertEquals("user notes", File(base, "rootfs/root/workspace/notes.txt").readText())
            for (path in listOf("engine.upgrade", "engine.done", "staging")) {
                assertFalse("leftover $path after $step", File(base, path).exists())
            }
        }
    }

    @Test fun sameVersionRepairWithoutAJournalStillReservesAnArchive() {
        installed("new")
        expectArchiveReservation("new")
    }

    @Test fun unpublishedPreparationDoesNotSkipSameVersionRepair() {
        installed("new")
        interruptUpgrade("new", "prepared")
        expectArchiveReservation("new")
    }

    @Test fun aJournalFromAnEarlierApkStillNeedsTheCurrentArchive() {
        installed("old")
        interruptUpgrade("previous", "journal")
        expectArchiveReservation("new")
        assertEquals("previous", File(base, "rootfs.version").readText())
        assertFalse(File(base, "engine.upgrade").exists())
    }
}
