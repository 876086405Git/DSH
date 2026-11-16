package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File
import java.nio.file.Files
import java.nio.file.Paths
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

class GuestAgentsModeTest {
    @Test fun managedInstructionsUseTheSelectedLocale() {
        val root = kotlin.io.path.createTempDirectory("agents-locale").toFile()
        try {
            val file = File(root, "root/.dsh/AGENTS.md")
            GuestSetup.writeAgentsMd(root, phoneStorage = true, phoneControl = true)
            val original = file.readBytes()
            assertTrue(file.readText().contains("# 运行环境（DSH 手机版）"))

            GuestSetup.writeAgentsMd(root, phoneStorage = true, phoneControl = true, nativeLocale = "en")
            val english = file.readText()
            assertTrue(english.contains("# Runtime environment (DSH mobile app)"))
            assertTrue(english.contains("## Interface and skills"))
            assertTrue(english.contains("## Visual replies (dsh-ui)"))
            assertTrue(english.contains("## Phone control"))
            assertTrue(english.contains("## Local diagnostics"))
            assertTrue(english.contains("Ubuntu 24.04 environment (proot, no root required)"))
            assertTrue(english.contains("`/sdcard/Download/DSH-Go/`"))
            assertFalse(english.contains("# 运行环境（DSH 手机版）"))

            GuestSetup.writeAgentsMd(root, phoneStorage = true, phoneControl = true, directEngine = true, nativeLocale = "en")
            val direct = file.readText()
            assertTrue(direct.contains("the engine starts directly; bash/git/python/apt tools still run through proot"))
            assertTrue(direct.contains("`${root.canonicalPath}/root/workspace`"))
            assertTrue(direct.contains("`${root.canonicalPath}/root/.dsh/dsh-app/diagnostics.md`"))

            GuestSetup.writeAgentsMd(root, phoneStorage = true, phoneControl = true, nativeLocale = "zh-CN")
            assertArrayEquals(original, file.readBytes())
        } finally { root.deleteRecursively() }
    }

    @Test fun identicalEnglishInstructionsAreNotRewritten() {
        val root = kotlin.io.path.createTempDirectory("agents-locale-unchanged").toFile()
        try {
            val file = File(root, "root/.dsh/AGENTS.md")
            GuestSetup.writeAgentsMd(root, phoneStorage = false, nativeLocale = "en")
            val original = file.readBytes()
            assertTrue(file.setLastModified(1_234_567_000L))
            val modified = file.lastModified()
            GuestSetup.writeAgentsMd(root, phoneStorage = false, nativeLocale = "en")
            assertArrayEquals(original, file.readBytes())
            assertEquals(modified, file.lastModified())
        } finally { root.deleteRecursively() }
    }

    @Test fun aLocaleChangeLeavesUserOwnedInstructionsUntouched() {
        val root = kotlin.io.path.createTempDirectory("agents-locale-user").toFile()
        try {
            val file = File(root, "root/.dsh/AGENTS.md").apply { parentFile!!.mkdirs() }
            val original = "# My own instructions\nKeep this exact text.\n".toByteArray()
            file.writeBytes(original)
            assertTrue(file.setLastModified(1_234_567_000L))
            val modified = file.lastModified()
            GuestSetup.writeAgentsMd(root, phoneStorage = true, phoneControl = true, directEngine = true, nativeLocale = "en")
            assertArrayEquals(original, file.readBytes())
            assertEquals(modified, file.lastModified())
        } finally { root.deleteRecursively() }
    }

    private fun tawcBackup(root: File, file: File): File {
        val obj = File(root.parentFile, "tawcroot/link/123").apply { parentFile!!.mkdirs() }
        Files.move(file.toPath(), obj.toPath())
        File(obj.parentFile, "123.cnt").writeText("0000000002\n")
        val target = Paths.get("tawcroot:link:123")
        Files.createSymbolicLink(file.toPath(), target)
        Files.createSymbolicLink(File(root, "root/agents-backup.md").toPath(), target)
        return obj
    }

    @Test fun tawcUserOwnedInstructionsRemainUntouchedAcrossLaunchModes() {
        val base = kotlin.io.path.createTempDirectory("agents-tawc-user").toFile()
        val root = File(base, "rootfs")
        try {
            val file = File(root, "root/.dsh/AGENTS.md").apply { parentFile!!.mkdirs() }
            val original = "# My own instructions\nKeep them across startup.\n".toByteArray()
            file.writeBytes(original)
            val obj = tawcBackup(root, file)
            assertFalse(file.exists())
            for (direct in listOf(false, true)) {
                GuestSetup.writeAgentsMd(root, phoneStorage = true, phoneControl = true, directEngine = direct)
                assertEquals("tawcroot:link:123", Files.readSymbolicLink(file.toPath()).toString())
                assertArrayEquals(original, obj.readBytes())
            }
            assertEquals("tawcroot:link:123", Files.readSymbolicLink(File(root, "root/agents-backup.md").toPath()).toString())
        } finally { base.deleteRecursively() }
    }

    @Test fun tawcManagedInstructionsSkipIdenticalBytesAndKeepTheBackupOnUpdate() {
        val base = kotlin.io.path.createTempDirectory("agents-tawc-managed").toFile()
        val root = File(base, "rootfs")
        try {
            GuestSetup.writeAgentsMd(root, phoneStorage = false)
            val file = File(root, "root/.dsh/AGENTS.md")
            val original = file.readBytes()
            val obj = tawcBackup(root, file)
            assertTrue(obj.setLastModified(1_234_567_000L))
            val modified = obj.lastModified()

            GuestSetup.writeAgentsMd(root, phoneStorage = false)
            assertTrue(Files.isSymbolicLink(file.toPath()))
            assertEquals(modified, obj.lastModified())
            GuestSetup.writeAgentsMd(root, phoneStorage = true)
            assertFalse(Files.isSymbolicLink(file.toPath()))
            assertTrue(file.readText().contains("`/sdcard/Download/DSH-Go/`"))
            assertArrayEquals(original, obj.readBytes())
            assertEquals("tawcroot:link:123", Files.readSymbolicLink(File(root, "root/agents-backup.md").toPath()).toString())
        } finally { base.deleteRecursively() }
    }

    @Test fun aManagedInstructionsLinkIsKeptWhileItsTargetIsUpdated() {
        assumeTrue("Linux symlink regression", System.getProperty("os.name").startsWith("Linux"))
        val root = kotlin.io.path.createTempDirectory("agents-link").toFile()
        try {
            val file = File(root, "root/.dsh/AGENTS.md")
            val target = File(root, "managed-instructions.md")
            GuestSetup.writeAgentsMd(root, phoneStorage = false)
            Files.move(file.toPath(), target.toPath())
            Files.createSymbolicLink(file.toPath(), target.toPath())
            GuestSetup.writeAgentsMd(root, phoneStorage = false, directEngine = true)
            assertTrue(Files.isSymbolicLink(file.toPath()))
            assertTrue(target.readText().contains("`${root.canonicalPath}/root/workspace`"))
            assertEquals(target.readText(), file.readText())
        } finally { root.deleteRecursively() }
    }

    @Test fun compatibleLaunchRestoresTheExactOriginalDefaultInstructionsAfterDirect() {
        val root = kotlin.io.path.createTempDirectory("agents-mode").toFile()
        try {
            val file = File(root, "root/.dsh/AGENTS.md")
            GuestSetup.writeAgentsMd(root, phoneStorage = false)
            val original = file.readBytes()
            assertTrue(file.readText().contains("`/root/workspace`"))
            GuestSetup.writeAgentsMd(root, phoneStorage = false, directEngine = true)
            assertTrue(file.readText().contains("`${root.canonicalPath}/root/workspace`"))
            assertFalse(original.contentEquals(file.readBytes()))
            GuestSetup.writeAgentsMd(root, phoneStorage = false, directEngine = false)
            assertArrayEquals(original, file.readBytes())
        } finally { root.deleteRecursively() }
    }

    @Test fun aUserOwnedFileIsUnchangedAcrossBothLaunchModes() {
        val root = kotlin.io.path.createTempDirectory("agents-user").toFile()
        try {
            val file = File(root, "root/.dsh/AGENTS.md")
            file.parentFile.mkdirs()
            val original = "# My own workspace instructions\nKeep my paths and examples.\n".toByteArray()
            file.writeBytes(original)
            for (direct in listOf(true, false)) {
                GuestSetup.writeAgentsMd(root, phoneStorage = true, phoneControl = true, directEngine = direct)
                assertArrayEquals(original, file.readBytes())
            }
        } finally { root.deleteRecursively() }
    }

    @Test fun phoneStorageSendsOutputsToTheDshGoFolder() {
        val root = kotlin.io.path.createTempDirectory("agents-storage").toFile()
        try {
            GuestSetup.writeAgentsMd(root, phoneStorage = true)
            val text = File(root, "root/.dsh/AGENTS.md").readText()
            // The folder FilesPlugin saves into and lists, with no space to quote in shell commands.
            assertTrue(text.contains("给用户的产出文件放到 `/sdcard/Download/DSH-Go/`。"))
            assertFalse(text.contains("/sdcard/Download/DSH/"))
        } finally { root.deleteRecursively() }
    }

    @Test fun diagnosticsSectionNamesThePathForEachLaunchMode() {
        val root = kotlin.io.path.createTempDirectory("agents-diagnostics").toFile()
        try {
            val file = File(root, "root/.dsh/AGENTS.md")
            GuestSetup.writeAgentsMd(root, phoneStorage = false)
            val proot = file.readText()
            assertTrue(proot.contains("## 本机诊断"))
            assertTrue(proot.contains("`\$DSH_HOME/dsh-app/diagnostics.md`"))
            assertTrue(proot.contains("dsh-go-support"))
            GuestSetup.writeAgentsMd(root, phoneStorage = false, directEngine = true)
            val direct = file.readText()
            assertTrue(direct.contains("`${root.canonicalPath}/root/.dsh/dsh-app/diagnostics.md`"))
            assertFalse(direct.contains("\$DSH_HOME/dsh-app/diagnostics.md"))
        } finally { root.deleteRecursively() }
    }

    @Test fun diagnosticsSnapshotIsWrittenWhereTheEngineCanReadIt() {
        val root = kotlin.io.path.createTempDirectory("agents-write").toFile()
        try {
            val file = GuestSetup.writeDiagnostics(root, "# first\n")
            assertEquals(File(root, "root/.dsh/dsh-app/diagnostics.md").absoluteFile, file.absoluteFile)
            assertEquals("# first\n", file.readText())
            GuestSetup.writeDiagnostics(root, "# second\n")
            assertEquals("# second\n", file.readText())
            assertEquals(0, file.parentFile!!.listFiles()!!.count { it.name.startsWith(".diagnostics") })
        } finally { root.deleteRecursively() }
    }

    @Test fun safeDiagnosticsLeaveOriginalHomeUntouchedAndNormalDiagnosticsReturnToIt() {
        val root = kotlin.io.path.createTempDirectory("diagnostics-safe").toFile()
        try {
            val original = GuestSetup.writeDiagnostics(root, "# original\n")
            val originalBytes = original.readBytes()
            val safeFile = GuestSetup.writeDiagnostics(root, "# rescue\n", safe = true)
            assertEquals(
                File(root, "var/lib/dsh-app/safe-mode/home/dsh-app/diagnostics.md").absoluteFile,
                safeFile.absoluteFile,
            )
            assertEquals("# rescue\n", safeFile.readText())
            assertArrayEquals(originalBytes, original.readBytes())
            val normalFile = GuestSetup.writeDiagnostics(root, "# normal again\n")
            assertEquals(original.absoluteFile, normalFile.absoluteFile)
            assertEquals("# normal again\n", original.readText())
            assertEquals("# rescue\n", safeFile.readText())
        } finally { root.deleteRecursively() }
    }

    @Test fun safeDiagnosticsDoNotNeedTheOriginalHomeToBeADirectory() {
        val root = kotlin.io.path.createTempDirectory("diagnostics-broken-home").toFile()
        try {
            val originalHome = File(root, "root/.dsh")
            originalHome.parentFile.mkdirs()
            val originalBytes = "original path is not a directory\n".toByteArray()
            originalHome.writeBytes(originalBytes)
            val safeFile = GuestSetup.writeDiagnostics(root, "# rescue\n", safe = true)
            assertEquals("# rescue\n", safeFile.readText())
            assertArrayEquals(originalBytes, originalHome.readBytes())
            assertEquals(0, safeFile.parentFile!!.listFiles()!!.count { it.name.startsWith(".diagnostics") })
        } finally { root.deleteRecursively() }
    }

    @Test fun unchangedDefaultStartupDoesNotRewriteAnExistingManagedFile() {
        val root = kotlin.io.path.createTempDirectory("agents-unchanged").toFile()
        try {
            val file = File(root, "root/.dsh/AGENTS.md")
            GuestSetup.writeAgentsMd(root, phoneStorage = true, visualReplies = false)
            val original = file.readBytes()
            assertTrue(file.setLastModified(1_234_567_000L))
            val modified = file.lastModified()
            GuestSetup.writeAgentsMd(root, phoneStorage = true, visualReplies = false, directEngine = false)
            assertArrayEquals(original, file.readBytes())
            assertEquals(modified, file.lastModified())
        } finally { root.deleteRecursively() }
    }
}
