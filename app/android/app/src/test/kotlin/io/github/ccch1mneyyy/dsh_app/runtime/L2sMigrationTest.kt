package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.Paths
import java.nio.file.attribute.FileTime
import java.nio.file.attribute.PosixFilePermissions
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

/**
 * Fixtures are built the way PRoot 5.1.107.102's link2symlink builds them
 * (src/extension/link2symlink/link2symlink.c, move_and_symlink_path and
 * decrement_link_count), matching what an emulator install showed: a name's
 * symlink and the intermediate both hold host-absolute paths into the store.
 */
class L2sMigrationTest {
    private val base = kotlin.io.path.createTempDirectory("l2s-migration").toFile()
    private val root = File(base, "rootfs").apply { mkdirs() }.canonicalFile
    private val store = File(root, "root/.l2s").apply { mkdirs() }.toPath()

    @After fun cleanUp() { base.deleteRecursively() }

    private fun file(path: String, text: String, mode: String = "rw-r--r--"): File =
        File(root, path).apply {
            parentFile.mkdirs()
            writeText(text)
            Files.setPosixFilePermissions(toPath(), PosixFilePermissions.fromString(mode))
        }

    /** PRoot's link(old, new) under --link2symlink with PROOT_L2S_DIR = the store. */
    private fun link(old: String, new: String) {
        val original = File(root, old).toPath()
        val name = File(root, new).toPath().also { Files.createDirectories(it.parent) }
        val intermediate: Path
        if (Files.isSymbolicLink(original)) {
            intermediate = Files.readSymbolicLink(original)
            val final = Files.readSymbolicLink(intermediate).toString()
            val next = Paths.get(final.dropLast(4) + "%04d".format(final.takeLast(4).toInt() + 1))
            Files.move(Paths.get(final), next)
            Files.delete(intermediate)
            Files.createSymbolicLink(intermediate, next)
        } else {
            var suffix = 1
            var candidate: Path
            // access(2) follows: a dangling intermediate counts as a free slot.
            do candidate = store.resolve(".l2s." + original.fileName + "%04d".format(suffix++)) while (Files.exists(candidate))
            intermediate = candidate
            val final = Paths.get("$intermediate.0002")
            Files.move(original, final)
            Files.createSymbolicLink(intermediate, final)
            Files.createSymbolicLink(original, intermediate)
        }
        Files.createSymbolicLink(name, intermediate)
    }

    /** PRoot's unlink(name): lower the count of a fake link (dropping its file at zero), then unlink. */
    private fun unlink(path: String) {
        val name = File(root, path).toPath()
        if (Files.isSymbolicLink(name)) {
            val intermediate = Files.readSymbolicLink(name)
            if (intermediate.fileName.toString().startsWith(".l2s.") && Files.isSymbolicLink(intermediate)) {
                val final = Files.readSymbolicLink(intermediate).toString()
                val count = final.takeLast(4).toInt() - 1
                if (count > 0) {
                    val next = Paths.get(final.dropLast(4) + "%04d".format(count))
                    Files.move(Paths.get(final), next)
                    Files.delete(intermediate)
                    Files.createSymbolicLink(intermediate, next)
                } else {
                    Files.delete(intermediate)
                    Files.delete(Paths.get(final))
                }
            }
        }
        Files.delete(name)
    }

    private fun text(path: String) = File(root, path).readText()
    private fun regular(path: String) = Files.isRegularFile(File(root, path).toPath(), LinkOption.NOFOLLOW_LINKS)
    private fun symlink(path: String) = Files.isSymbolicLink(File(root, path).toPath())
    private fun storeEntries() = Files.list(store).use { it.map { p -> p.fileName.toString() }.sorted().toList() }
    private fun temps() = root.walkTopDown().filter { L2sMigration.TEMP.matches(it.name) }.toList()
    private fun migrate(free: Long = Long.MAX_VALUE, flush: () -> Unit = {}, beforeRename: () -> Unit = {}, binds: List<String> = BINDS) =
        L2sMigration(root, flush, { free }, binds).run(beforeRename = beforeRename)

    /** chmod 000 for [block], as PRoot's bind placeholders read to the app on Android 16. */
    private fun <T> unreadable(path: String, block: () -> T): T {
        val dir = File(root, path).apply { mkdirs() }.toPath()
        Files.setPosixFilePermissions(dir, PosixFilePermissions.fromString("---------"))
        try { return block() } finally { Files.setPosixFilePermissions(dir, PosixFilePermissions.fromString("rwxr-xr-x")) }
    }

    @Test fun singleLinkBecomesTwoRealFilesAndEmptiesTheStore() {
        file("root/a", "hi\n")
        link("root/a", "root/b")
        assertEquals(listOf(".l2s.a0001", ".l2s.a0001.0002"), storeEntries())
        assertEquals("$store/.l2s.a0001", Files.readSymbolicLink(File(root, "root/b").toPath()).toString())

        assertEquals(L2sMigration.Result.Done(links = 2, removed = 0), migrate())
        for (name in listOf("root/a", "root/b")) {
            assertTrue(name, regular(name))
            assertEquals("hi\n", text(name))
        }
        assertEquals(emptyList<String>(), storeEntries())
        assertTrue(Files.isDirectory(store, LinkOption.NOFOLLOW_LINKS))
        assertNull(DirectLaunch.compatibilityReason(root))
    }

    @Test fun manyNamesAcrossNestedDirectoriesKeepTheirContentAndAreIndependentAfterwards() {
        file("root/a", "shared")
        link("root/a", "root/b")
        link("root/a", "root/d/c")
        link("root/b", "root/.local/share/pnpm/store/v10/files/ab/cdef")
        link("root/d/c", "root/plugins/x/node_modules/.pnpm/p@1/node_modules/p/index.js")
        assertTrue(storeEntries().contains(".l2s.a0001.0005"))

        assertEquals(5, (migrate() as L2sMigration.Result.Done).links)
        val names = listOf("root/a", "root/b", "root/d/c", "root/.local/share/pnpm/store/v10/files/ab/cdef",
            "root/plugins/x/node_modules/.pnpm/p@1/node_modules/p/index.js")
        for (name in names) {
            assertTrue(name, regular(name))
            assertEquals("shared", text(name))
        }
        File(root, "root/b").writeText("changed")
        assertEquals("shared", text("root/a"))
        assertEquals(emptyList<String>(), storeEntries())
    }

    @Test fun relativeAndGuestAbsoluteTargetsIntoTheStoreCountAsNames() {
        file("root/a", "x")
        link("root/a", "root/b")
        Files.createSymbolicLink(File(root, "root/rel").toPath(), Paths.get(".l2s/.l2s.a0001"))
        Files.createSymbolicLink(File(root, "opt/guest").apply { parentFile.mkdirs() }.toPath(), Paths.get("/root/.l2s/.l2s.a0001"))
        Files.createSymbolicLink(File(root, "opt/up").toPath(), Paths.get("../root/./.l2s/.l2s.a0001.0002"))

        assertEquals(5, (migrate() as L2sMigration.Result.Done).links)
        for (name in listOf("root/a", "root/b", "root/rel", "opt/guest", "opt/up")) {
            assertTrue(name, regular(name))
            assertEquals("x", text(name))
        }
        assertEquals(emptyList<String>(), storeEntries())
    }

    @Test fun otherSymlinksStayExactlyAsTheyWere() {
        file("etc/real", "r")
        file("root/a", "x")
        link("root/a", "root/b")
        val outside = File(base, "outside").apply { writeText("host") }
        val links = mapOf(
            "usr/bin/guest-abs" to "/etc/real",
            "usr/bin/relative" to "../../etc/real",
            "usr/bin/host-outside" to outside.path,
            "root/phone" to "/sdcard",
            "root/dir-link" to "/root",
            "root/dangling" to "/nowhere/.l2s/.l2s.a0001",
            "root/near-store" to "/root/.l2s-not/.l2s.a0001",
        )
        for ((path, target) in links) Files.createSymbolicLink(File(root, path).apply { parentFile.mkdirs() }.toPath(), Paths.get(target))

        migrate()
        for ((path, target) in links) {
            assertTrue(path, symlink(path))
            assertEquals(target, Files.readSymbolicLink(File(root, path).toPath()).toString())
        }
        assertEquals("host", outside.readText())
        assertEquals("r", text("etc/real"))
    }

    @Test fun permissionBitsAndModificationTimeCarryOverToEveryName() {
        file("usr/lib/tool", "#!/bin/sh\n", mode = "rwxr-x---")
        val mtime = FileTime.fromMillis(1_600_000_000_000L)
        Files.setLastModifiedTime(File(root, "usr/lib/tool").toPath(), mtime)
        link("usr/lib/tool", "usr/bin/tool")
        link("usr/lib/tool", "usr/sbin/tool")
        val readOnly = file("root/ro", "ro", mode = "r--r--r--")
        link("root/ro", "root/ro2")

        migrate()
        for (name in listOf("usr/lib/tool", "usr/bin/tool", "usr/sbin/tool")) {
            val path = File(root, name).toPath()
            assertTrue(name, regular(name))
            assertEquals(name, "rwxr-x---", PosixFilePermissions.toString(Files.getPosixFilePermissions(path, LinkOption.NOFOLLOW_LINKS)))
            assertEquals(name, mtime, Files.getLastModifiedTime(path, LinkOption.NOFOLLOW_LINKS))
        }
        for (name in listOf("root/ro", "root/ro2")) {
            assertEquals(name, "r--r--r--", PosixFilePermissions.toString(Files.getPosixFilePermissions(File(root, name).toPath())))
            assertEquals("ro", text(name))
        }
        assertFalse(readOnly.canWrite())
    }

    @Test fun orphanFilesAndDanglingIntermediatesAreRemovedButDirectoriesStay() {
        file("root/a", "x")
        link("root/a", "root/b")
        // Names deleted outside PRoot: the count says 3, nothing names the file.
        Files.write(store.resolve(".l2s.gone0001.0003"), "orphan".toByteArray())
        Files.createSymbolicLink(store.resolve(".l2s.gone0001"), store.resolve(".l2s.gone0001.0003"))
        Files.createSymbolicLink(store.resolve(".l2s.lost0001"), store.resolve(".l2s.lost0001.0002"))

        val result = migrate() as L2sMigration.Result.Done
        assertEquals(2, result.links)
        assertEquals(3, result.removed)
        assertEquals(emptyList<String>(), storeEntries())

        Files.createDirectory(store.resolve("not-proot"))
        file("root/c", "y")
        link("root/c", "root/d")
        migrate()
        assertEquals(listOf("not-proot"), storeEntries())
        assertEquals(DirectLaunch.INCOMPATIBLE, DirectLaunch.compatibilityReason(root))
        assertTrue(regular("root/c") && regular("root/d"))
    }

    @Test fun aStaleIntermediateKeepsTheRenamedBackingForRecovery() {
        assertDamagedChainKeepsBacking(removeIntermediate = false)
    }

    @Test fun aMissingIntermediateKeepsTheRenamedBackingForRecovery() {
        assertDamagedChainKeepsBacking(removeIntermediate = true)
    }

    private fun assertDamagedChainKeepsBacking(removeIntermediate: Boolean) {
        file("root/staged", "recoverable")
        link("root/staged", "root/published")
        val intermediate = Files.readSymbolicLink(File(root, "root/published").toPath())
        val backing = Files.readSymbolicLink(intermediate)
        val renamedBacking = Paths.get(backing.toString().dropLast(4) + "0001")
        // .98 decrements before unlink: the backing has moved, but updating
        // the intermediate either has not happened or failed after its unlink.
        Files.move(backing, renamedBacking)
        if (removeIntermediate) Files.delete(intermediate)
        assertFalse(Files.exists(File(root, "root/published").toPath()))
        file("root/healthy", "healthy")
        link("root/healthy", "root/healthy2")

        assertEquals(L2sMigration.Result.Done(links = 2, removed = 0), migrate())
        assertTrue(regular("root/healthy") && regular("root/healthy2"))
        assertEquals("healthy", text("root/healthy2"))
        assertEquals("recoverable", String(Files.readAllBytes(renamedBacking), Charsets.UTF_8))
        assertTrue(symlink("root/staged") && symlink("root/published"))
        assertEquals(!removeIntermediate, Files.isSymbolicLink(intermediate))
        assertEquals(DirectLaunch.INCOMPATIBLE, DirectLaunch.compatibilityReason(root))
        val beforeRetry = storeEntries()
        assertEquals(L2sMigration.Result.Done(links = 0, removed = 0), migrate())
        assertEquals(beforeRetry, storeEntries())
        assertEquals("recoverable", String(Files.readAllBytes(renamedBacking), Charsets.UTF_8))
    }

    @Test fun aLinkMadeToAStoredFileItselfNestsAndStillResolves() {
        file("root/a", "nested")
        link("root/a", "root/b")
        // `ln /root/.l2s/.l2s.a0001.0002 /root/x` under PRoot moves the stored file once more.
        link("root/.l2s/.l2s.a0001.0002", "root/x")
        assertTrue(Files.isSymbolicLink(store.resolve(".l2s.a0001.0002")))

        assertEquals(3, (migrate() as L2sMigration.Result.Done).links)
        for (name in listOf("root/a", "root/b", "root/x")) assertEquals("nested", text(name))
        assertTrue(regular("root/a") && regular("root/b") && regular("root/x"))
        assertEquals(emptyList<String>(), storeEntries())
    }

    @Test fun notEnoughSpaceChangesNothing() {
        file("root/a", "x".repeat(10_000))
        link("root/a", "root/b")
        link("root/a", "root/c")
        val before = storeEntries()
        val result = migrate(free = L2sMigration.MARGIN) as L2sMigration.Result.NotEnoughSpace
        assertEquals(2 * (4096 + 12_288L), result.need)
        assertEquals(before, storeEntries())
        assertTrue(symlink("root/a") && symlink("root/b") && symlink("root/c"))
        assertEquals("x".repeat(10_000), text("root/c"))

        // A file left with one name needs no copy, hence no room.
        unlink("root/b")
        unlink("root/c")
        assertEquals(L2sMigration.Result.Done(1, 0), migrate(free = 0))
        assertTrue(regular("root/a"))
    }

    @Test fun aLimitedCopyIgnoresLaunchMarginAndLeavesOtherNamesAndStoreIntact() {
        file("root/source", "kept")
        link("root/source", "root/selected")
        link("root/source", "root/unselected")
        val before = storeEntries()

        val result = L2sMigration(root, {}, { 0 }, within = File(root, "root/selected")).run()

        assertEquals(L2sMigration.Result.Done(1, 0), result)
        assertTrue(regular("root/selected"))
        assertTrue(symlink("root/source") && symlink("root/unselected"))
        assertEquals(before, storeEntries())
        File(root, "root/selected").writeText("independent")
        assertEquals("kept", text("root/source"))
        assertEquals("kept", text("root/unselected"))
    }

    @Test fun limitedCopiesResumeAfterFlushOrPublicationInterruption() {
        for (duringFlush in listOf(true, false)) {
            base.listFiles()!!.forEach { it.deleteRecursively() }
            Files.createDirectories(store)
            file("root/source", "original")
            link("root/source", "root/kept/a")
            link("root/source", "root/kept/b")
            val before = storeEntries()
            var renames = 0
            try {
                L2sMigration(root, {
                    if (duringFlush) throw java.io.IOException("flush interrupted")
                }, { 0 }, within = File(root, "root/kept")).run(beforeRename = {
                    if (renames++ == 1) throw java.io.IOException("publication interrupted")
                })
                fail("expected interruption")
            } catch (e: java.io.IOException) {
                assertEquals(if (duringFlush) "flush interrupted" else "publication interrupted", e.message)
            }
            assertEquals(before, storeEntries())
            for (name in listOf("root/source", "root/kept/a", "root/kept/b")) assertEquals("original", text(name))
            assertTrue(symlink("root/source"))
            assertTrue(symlink("root/kept/b"))
            assertEquals(!duringFlush, regular("root/kept/a"))
            assertTrue(temps().isEmpty())

            val result = L2sMigration(root, {}, { 0 }, within = File(root, "root/kept")).run()
            assertEquals(L2sMigration.Result.Done(if (duringFlush) 2 else 1, 0), result)
            assertTrue(regular("root/kept/a") && regular("root/kept/b"))
            assertTrue(symlink("root/source"))
            assertEquals("original", text("root/source"))
            assertEquals(before, storeEntries())
        }
    }

    @Test fun copiesAreFlushedBeforeAnyNameIsReplacedOncePerBatch() {
        file("root/a", "x")
        repeat(2_100) { link("root/a", "root/many/n$it") }
        var flushes = 0
        val result = migrate(flush = {
            flushes++
            assertTrue(temps().isNotEmpty())
            if (flushes == 1) assertTrue((0 until 2_100).all { symlink("root/many/n$it") })
        }) as L2sMigration.Result.Done
        // One stored file is one group: its copies go in one batch.
        assertEquals(1, flushes)
        assertEquals(2_101, result.links)
        assertTrue(temps().isEmpty())

        for (i in 0 until 3) {
            file("root/f$i", "f$i".repeat(10))
            repeat(1_000) { link("root/f$i", "root/more$i/n$it") }
        }
        flushes = 0
        migrate(flush = { flushes++ })
        assertEquals(2, flushes)
        assertEquals("f2f2f2f2f2f2f2f2f2f2", text("root/more2/n999"))
    }

    /** What PRoot needs at any point: each remaining symlink reaches a stored file whose count covers them all. */
    private fun assertProotConsistent(contents: Map<String, String>) {
        for ((name, content) in contents) assertEquals(name, content, text(name))
        val symlinksPerFile = HashMap<Path, Int>()
        root.walkTopDown().onEnter { it.toPath() != store }.filter { Files.isSymbolicLink(it.toPath()) }.forEach {
            val intermediate = Files.readSymbolicLink(it.toPath())
            if (intermediate.parent == store) symlinksPerFile.merge(Files.readSymbolicLink(intermediate), 1, Int::plus)
        }
        for ((final, count) in symlinksPerFile) assertTrue("$final has $count names", final.toString().takeLast(4).toInt() >= count)
        assertTrue(temps().isEmpty())
    }

    private fun fixture(): Map<String, String> {
        file("root/a", "A")
        link("root/a", "root/b")
        link("root/a", "root/d/c")
        file("usr/lib/one", "ONE", mode = "rwxr-xr-x")
        link("usr/lib/one", "usr/bin/one")
        file("root/solo", "SOLO")
        link("root/solo", "root/solo2")
        unlink("root/solo2")
        return mapOf("root/a" to "A", "root/b" to "A", "root/d/c" to "A", "usr/lib/one" to "ONE", "usr/bin/one" to "ONE", "root/solo" to "SOLO")
    }

    @Test fun anInterruptionAtAnyStepLosesNothingAndTheNextRunFinishes() {
        var steps = 0
        fixture()
        migrate(beforeRename = { steps++ })
        assertEquals(6, steps)
        for (stop in 0 until steps) {
            base.listFiles()!!.forEach { it.deleteRecursively() }
            Files.createDirectories(store)
            val contents = fixture()
            var at = 0
            try {
                migrate(beforeRename = { if (at++ == stop) throw java.io.IOException("killed at $stop") })
                fail("no interruption at $stop")
            } catch (e: java.io.IOException) {
                assertEquals("killed at $stop", e.message)
            }
            assertProotConsistent(contents)
            migrate()
            for ((name, content) in contents) {
                assertTrue("$stop $name", regular(name))
                assertEquals(content, text(name))
            }
            assertEquals("stop $stop", emptyList<String>(), storeEntries())
        }
    }

    @Test fun aCopyLeftByAKilledRunIsRemovedAndLookalikeUserFilesStay() {
        file("root/a", "x")
        link("root/a", "root/b")
        val leftover = file("root/.dsh-go-l2s-0123456789abcdef.tmp", "partial copy")
        val user = file("root/.dsh-go-l2s-notes.tmp", "mine")
        val alsoUser = file("root/.dsh-go-l2s-0123456789ABCDEF.tmp", "mine too")

        migrate()
        assertFalse(leftover.exists())
        assertEquals("mine", user.readText())
        assertEquals("mine too", alsoUser.readText())
    }

    @Test fun prootKeepsWorkingOnAHalfDoneTreeAndTheNextRunPicksUpWhatChanged() {
        file("root/a", "A")
        link("root/a", "root/b")
        link("root/a", "root/c")
        link("root/a", "root/d")
        file("root/z", "Z")
        link("root/z", "root/y")
        // Stop after the first copy of `a` replaced its name: b, c, d stay PRoot's.
        var at = 0
        runCatching { migrate(beforeRename = { if (at++ == 1) throw java.io.IOException("killed") }) }
        assertTrue(regular("root/a") && symlink("root/b") && symlink("root/c") && symlink("root/d"))
        assertTrue(storeEntries().contains(".l2s.a0001.0004"))

        // PRoot reads every name, drops two of the remaining links, links again both kinds of name.
        for ((name, content) in mapOf("root/a" to "A", "root/b" to "A", "root/c" to "A", "root/d" to "A", "root/z" to "Z", "root/y" to "Z")) {
            assertEquals(name, content, text(name))
        }
        unlink("root/b")
        unlink("root/c")
        assertEquals("A", text("root/d")) // count 4 -> 2, still one symlink: the file stays
        link("root/d", "root/e")
        link("root/a", "root/f")          // a is a real file now: a new stored file
        assertTrue(storeEntries().containsAll(listOf(".l2s.a0001.0003", ".l2s.a0002.0002")))
        unlink("root/d")
        unlink("root/e")                  // count 3 -> 1: no symlink left, the file is an orphan
        assertTrue(storeEntries().contains(".l2s.a0001.0001"))

        val result = migrate() as L2sMigration.Result.Done
        for ((name, content) in mapOf("root/a" to "A", "root/f" to "A", "root/z" to "Z", "root/y" to "Z")) {
            assertTrue(name, regular(name))
            assertEquals(content, text(name))
        }
        assertFalse(File(root, "root/b").exists() || File(root, "root/e").exists())
        assertEquals(4, result.links)
        assertEquals(emptyList<String>(), storeEntries())
    }

    @Test fun aSymlinkedStoreIsLeftAlone() {
        Files.delete(store)
        val elsewhere = File(base, "elsewhere").apply { mkdirs() }
        File(elsewhere, ".l2s.x0001.0002").writeText("keep")
        Files.createSymbolicLink(store, elsewhere.toPath())
        assertEquals(L2sMigration.Result.Done(0, 0), migrate())
        assertEquals("keep", File(elsewhere, ".l2s.x0001.0002").readText())
        assertEquals(DirectLaunch.INCOMPATIBLE, DirectLaunch.compatibilityReason(root))
    }

    @Test fun unreadableBindPlaceholdersAreSkippedAndTheMigrationCompletes() {
        file("root/a", "x")
        link("root/a", "root/b")
        // Orphans go too: nothing under a bind target can be a PRoot name.
        Files.write(store.resolve(".l2s.gone0001.0002"), "orphan".toByteArray())
        val result = unreadable("system") { unreadable("apex") { migrate() } }
        assertEquals(L2sMigration.Result.Done(links = 2, removed = 1), result)
        assertTrue(regular("root/a") && regular("root/b"))
        assertEquals(emptyList<String>(), storeEntries())
        assertNull(DirectLaunch.compatibilityReason(root))
    }

    @Test fun anyOtherUnreadableDirectoryStillStopsTheMigrationAndChangesNothing() {
        file("root/a", "x")
        link("root/a", "root/b")
        val before = storeEntries()
        // Without the bind, `system` is just a directory a name could hide in.
        for ((path, binds) in listOf("root/private" to BINDS, "system" to emptyList())) {
            try {
                unreadable(path) { migrate(binds = binds) }
                fail("$path: an unreadable directory was skipped")
            } catch (_: java.nio.file.AccessDeniedException) {}
            assertEquals(before, storeEntries())
            assertTrue(symlink("root/a") && symlink("root/b"))
            assertEquals("x", text("root/b"))
        }
    }

    @Test fun anUnreadablePlaceholderOnTheWayToABindKeepsEveryStoredFile() {
        file("root/a", "x")
        link("root/a", "root/b")
        Files.write(store.resolve(".l2s.gone0001.0002"), "orphan".toByteArray())
        // The rootfs alias (`-b <rootfs>:<rootfs>`) puts its placeholder chain under data/.
        val alias = "/data/user/0/io.github.ccch1mneyyy.dsh_app/files/runtime/rootfs"
        val result = unreadable("data") { migrate(binds = BINDS + alias) }
        assertEquals(L2sMigration.Result.Done(links = 2, removed = 0), result)
        assertTrue(regular("root/a") && regular("root/b"))
        assertEquals(listOf(".l2s.gone0001.0002"), storeEntries())
        assertEquals(DirectLaunch.INCOMPATIBLE, DirectLaunch.compatibilityReason(root))
    }

    @Test fun readableBindTargetsAreNotWalkedAndOddLinksAreLeftAlone() {
        file("root/a", "x")
        link("root/a", "root/b")
        // A stray name under a bind target is the host's to the guest, never PRoot's.
        File(root, "dev").mkdirs()
        Files.createSymbolicLink(File(root, "dev/stray").toPath(), store.resolve(".l2s.a0001"))
        File(root, "tmp").mkdirs()
        Files.createSymbolicLink(File(root, "tmp/dangling").toPath(), Paths.get("/nowhere"))
        Files.createSymbolicLink(File(root, "tmp/dangling-store").toPath(), store.resolve(".l2s.none0001"))
        Files.createSymbolicLink(File(root, "tmp/loop").toPath(), Paths.get("loop"))

        assertEquals(2, (migrate() as L2sMigration.Result.Done).links)
        assertTrue(regular("root/a") && regular("root/b"))
        assertTrue(symlink("dev/stray") && symlink("tmp/dangling") && symlink("tmp/dangling-store") && symlink("tmp/loop"))
    }

    @Test fun bindTargetsAreTheGuestSidesOfTheLaunchBinds() {
        val argv = listOf("{NATIVE_LIB_DIR}/libproot.so", "--kill-on-exit", "--link2symlink", "--sysvipc", "-L", "-0",
            "--rootfs={ROOTFS}", "--cwd=/root", "-b", "/dev", "-b", "/dev/urandom:/dev/random", "-b", "/proc",
            "-b", "/proc/self/fd:/dev/fd", "-b", "/sys", "-b", "{ROOTFS}/var/lib/dsh-app/empty:/sys/fs/selinux",
            "-b", "{ROOTFS}/var/lib/dsh-app/shm:/dev/shm", "-b", "/system", "-b", "/apex",
            "/usr/bin/env", "-i", "HOME=/root", "-b", "/not-a-bind", "/bin/sh", "-c", "exec dsh web")
        assertEquals(
            listOf("/dev", "/dev/random", "/proc", "/dev/fd", "/sys", "/sys/fs/selinux", "/dev/shm", "/system", "/apex",
                "/sdcard", "/storage", "/data/rootfs"),
            L2sMigration.bindTargets(argv, listOf("/storage/emulated/0:/sdcard", "/storage", "/data/rootfs:/data/rootfs")),
        )
    }

    private companion object {
        /** The guest sides of the runtime manifest's binds. */
        val BINDS = listOf("/dev", "/dev/random", "/proc", "/dev/fd", "/sys", "/sys/fs/selinux", "/dev/shm", "/system", "/apex")
    }
}
