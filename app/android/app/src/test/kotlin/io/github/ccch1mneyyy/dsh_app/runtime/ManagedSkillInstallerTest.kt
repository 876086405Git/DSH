package io.github.ccch1mneyyy.dsh_app.runtime

import io.github.ccch1mneyyy.dsh_app.phone.Json
import java.io.File
import java.nio.file.Files
import java.nio.file.Paths
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Test

class ManagedSkillInstallerTest {
    private val skill = "---\n# dsh-go:managed\nname: dsh-go-ui\n---\n中文 🐳\n"
    private fun files(value: String = "value") = linkedMapOf("SKILL.md" to skill, "nested/data.txt" to value)
    private fun root() = Files.createTempDirectory("managed-skill-").toFile().apply { File(this, "root/.dsh").mkdirs() }
    private fun args(root: File, id: String = "one", files: Map<String, String> = files(), name: String = "dsh-go-ui") =
        mapOf("requestId" to id, "expectedRoot" to root.path, "expectedToken" to "fixture-only", "expectedGeneration" to 1, "name" to name, "files" to files)
    private fun request(root: File, id: String = "one", files: Map<String, String> = files(), name: String = "dsh-go-ui") =
        ManagedSkillRequest.parse(args(root, id, files, name))!!
    private fun dir(root: File, name: String = "dsh-go-ui") = File(root, "root/.dsh/skills/$name")
    private fun noTemps(root: File) = assertFalse(root.walkTopDown().any { it.name.endsWith(".dsh-go-tmp") })
    private inline fun withRoot(test: (File) -> Unit) { val root = root(); try { test(root) } finally { root.deleteRecursively() } }

    /** Completed tawc NEW: both names point to the same sibling-store regular object. */
    private fun tawcBackup(root: File, file: File, token: String): File {
        val obj = File(root.parentFile, "tawcroot/link/$token").apply { parentFile!!.mkdirs() }
        Files.move(file.toPath(), obj.toPath())
        File(obj.parentFile, "$token.cnt").writeText("0000000002\n")
        val target = Paths.get("tawcroot:link:$token")
        Files.createSymbolicLink(file.toPath(), target)
        Files.createSymbolicLink(File(root, "root/backup-$token").toPath(), target)
        return obj
    }

    @Test fun firstInstallWritesExactUtf8AndCurrentInstallDoesNotWrite() = withRoot { root ->
        val request = request(root)
        assertEquals("installed", ManagedSkillInstaller.install(root, request) { true }.result)
        for ((path, text) in request.files) assertArrayEquals(text.toByteArray(), File(dir(root), path).readBytes())
        val times = request.files.keys.associateWith { File(dir(root), it).lastModified() }
        assertEquals("unchanged", ManagedSkillInstaller.install(root, request) { true }.result)
        for ((path, time) in times) assertEquals(time, File(dir(root), path).lastModified())
        noTemps(root)
    }

    @Test fun actualBundlesFitBudgetAndMatchEveryByte() = withRoot { root ->
        // Gradle runs unit tests in app/android/app; the Flutter app (and its
        // assets/) is two levels up. phase2.app still overrides it.
        val app = listOfNotNull(System.getProperty("phase2.app"), "../..", ".")
            .map(::File)
            .first { File(it, "assets/skills").isDirectory }
        var count = 0
        var size = 0
        for (name in listOf("dsh-go-ui", "dsh-go-plugin", "dsh-go-guide", "dsh-go-support", "companion-adapt", "pet-theme")) {
            val assets = File(app, "assets/skills/$name")
            val manifest = Json.parse(File(assets, "manifest.json").readText()) as Map<*, *>
            val bundled = (manifest["files"] as Map<*, *>).entries.associate { (asset, target) ->
                target as String to File(assets, asset as String).readText()
            }
            assertEquals("installed", ManagedSkillInstaller.install(root, request(root, name, bundled, name)) { true }.result)
            for ((path, text) in bundled) {
                assertArrayEquals(text.toByteArray(), File(dir(root, name), path).readBytes())
                count++; size += text.toByteArray().size
            }
        }
        assertTrue(count > 0)
        assertTrue(size > 0)
        println("managed-skill-assets files=$count utf8Bytes=$size")
        noTemps(root)
    }

    @Test fun repairsOnlyChangedOrMissingManagedFiles() = withRoot { root ->
        val request = request(root)
        ManagedSkillInstaller.install(root, request) { true }
        val skillFile = File(dir(root), "SKILL.md")
        val modified = skillFile.lastModified()
        File(dir(root), "nested/data.txt").writeText("broken")
        assertEquals("updated", ManagedSkillInstaller.install(root, request) { true }.result)
        assertEquals(modified, skillFile.lastModified())
        File(dir(root), "nested/data.txt").delete()
        assertEquals("updated", ManagedSkillInstaller.install(root, request) { true }.result)
        assertEquals("value", File(dir(root), "nested/data.txt").readText())
    }

    @Test fun removedMarkerLeavesEveryUserFileAlone() = withRoot { root ->
        ManagedSkillInstaller.install(root, request(root)) { true }
        File(dir(root), "SKILL.md").writeText(skill.replace("# dsh-go:managed", "# user-owned"))
        File(dir(root), "nested/data.txt").writeText("mine")
        assertEquals("userOwned", ManagedSkillInstaller.install(root, request(root)) { true }.result)
        assertEquals("mine", File(dir(root), "nested/data.txt").readText())
    }

    @Test fun tawcUserOwnedMarkerLeavesTheSkillAndOtherFilesUntouched() = withRoot { base ->
        val root = File(base, "rootfs").apply { File(this, "root/.dsh").mkdirs() }
        ManagedSkillInstaller.install(root, request(root)) { true }
        val file = File(dir(root), "SKILL.md")
        val userText = skill.replace("# dsh-go:managed", "# user-owned")
        file.writeText(userText)
        File(dir(root), "nested/data.txt").writeText("mine")
        val obj = tawcBackup(root, file, "123")
        assertFalse(file.exists()) // Android cannot follow tawc's opaque token.

        assertEquals("userOwned", ManagedSkillInstaller.install(root, request(root)) { true }.result)
        assertEquals("tawcroot:link:123", Files.readSymbolicLink(file.toPath()).toString())
        assertEquals("tawcroot:link:123", Files.readSymbolicLink(File(root, "root/backup-123").toPath()).toString())
        assertEquals(userText, obj.readText())
        assertEquals("mine", File(dir(root), "nested/data.txt").readText())
        noTemps(root)
    }

    @Test fun tawcManagedFilesSkipIdenticalBytesAndReplaceOnlyTheUpdatedName() = withRoot { base ->
        val root = File(base, "rootfs").apply { File(this, "root/.dsh").mkdirs() }
        ManagedSkillInstaller.install(root, request(root)) { true }
        val skillFile = File(dir(root), "SKILL.md")
        val dataFile = File(dir(root), "nested/data.txt")
        val skillObject = tawcBackup(root, skillFile, "123")
        val dataObject = tawcBackup(root, dataFile, "456-2")
        assertTrue(skillObject.setLastModified(1_234_567_000L))
        assertTrue(dataObject.setLastModified(1_234_567_000L))
        val times = listOf(skillObject.lastModified(), dataObject.lastModified())

        assertEquals("unchanged", ManagedSkillInstaller.install(root, request(root)) { true }.result)
        assertTrue(Files.isSymbolicLink(skillFile.toPath()))
        assertTrue(Files.isSymbolicLink(dataFile.toPath()))
        assertEquals(times, listOf(skillObject.lastModified(), dataObject.lastModified()))

        val updated = files("new value") + ("SKILL.md" to "${skill}updated\n")
        assertEquals("updated", ManagedSkillInstaller.install(root, request(root, files = updated)) { true }.result)
        assertEquals(updated.getValue("SKILL.md"), skillFile.readText())
        assertEquals("new value", dataFile.readText())
        assertFalse(Files.isSymbolicLink(skillFile.toPath()))
        assertFalse(Files.isSymbolicLink(dataFile.toPath()))
        assertEquals(skill, skillObject.readText())
        assertEquals("value", dataObject.readText())
        for (token in listOf("123", "456-2")) {
            assertEquals("tawcroot:link:$token", Files.readSymbolicLink(File(root, "root/backup-$token").toPath()).toString())
        }
        noTemps(root)
    }

    @Test fun markerOutsideFrontmatterDoesNotAuthorizeOverwrite() = withRoot { root ->
        File(dir(root), "SKILL.md").apply { parentFile!!.mkdirs(); writeText("---\nname: mine\n---\n# dsh-go:managed\n") }
        assertEquals("userOwned", ManagedSkillInstaller.install(root, request(root)) { true }.result)
        assertFalse(File(dir(root), "nested").exists())
    }

    @Test fun malformedExistingSkillIsUserOwnedAndBomMatchesDart() = withRoot { root ->
        val file = File(dir(root), "SKILL.md").apply { parentFile!!.mkdirs(); writeBytes(byteArrayOf(0xc3.toByte(), 0x28)) }
        assertEquals("userOwned", ManagedSkillInstaller.install(root, request(root)) { true }.result)
        file.writeText("\uFEFF$skill")
        File(dir(root), "nested/data.txt").apply { parentFile!!.mkdirs(); writeText("\uFEFFvalue") }
        assertEquals("unchanged", ManagedSkillInstaller.install(root, request(root)) { true }.result)
        assertTrue(file.readText().startsWith("\uFEFF"))
    }

    @Test fun absentDshHomeCreatesNothing() = withRoot { root ->
        File(root, "root").deleteRecursively()
        assertEquals("noHome", ManagedSkillInstaller.install(root, request(root)) { true }.result)
        assertFalse(File(root, "root").exists())
    }

    @Test fun wrongRootAndRetiredAdmissionCreateNothing() = withRoot { root ->
        val wrong = ManagedSkillRequest.parse(args(root) + ("expectedRoot" to File(root, "other").path))!!
        assertEquals("stale", ManagedSkillInstaller.install(root, wrong) { true }.reason)
        assertEquals("cancelled", ManagedSkillInstaller.install(root, request(root)) { false }.reason)
        assertFalse(dir(root).exists())
    }

    @Test fun pathAliasesToSameRootAreAcceptedOnlyAfterWorkerCanonicalCheck() = withRoot { root ->
        val alias = ManagedSkillRequest.parse(args(root) + ("expectedRoot" to root.path + "/./"))!!
        assertEquals("installed", ManagedSkillInstaller.install(root, alias) { true }.result)
    }

    @Test fun safeNamesAndPayloadBudgetsRejectTheEntireRequest() = withRoot { root ->
        for (bad in listOf("../data", "/data", "a/../../data", "a//b", "a/./b")) {
            assertNull(ManagedSkillRequest.parse(args(root, files = files() + (bad to "bad"))))
        }
        assertNull(ManagedSkillRequest.parse(args(root, name = "other")))
        assertNull(ManagedSkillRequest.parse(args(root, files = mapOf("data" to "no skill"))))
        assertNull(ManagedSkillRequest.parse(args(root, files = files() + ("big" to "x".repeat(524289)))))
        assertNull(ManagedSkillRequest.parse(args(root, files = (0..64).associate { "f$it" to "x" } + ("SKILL.md" to skill))))
        assertNull(ManagedSkillRequest.parse(args(root) + ("expectedToken" to "")))
        assertNull(ManagedSkillRequest.parse(args(root) - "expectedGeneration"))
        assertNull(ManagedSkillRequest.parse(args(root) + ("expectedGeneration" to 1.5)))
        assertNull(ManagedSkillRequest.parse(args(root) + ("expectedGeneration" to 1.0)))
        assertNull(ManagedSkillRequest.parse(args(root) + ("expectedGeneration" to 0)))
        assertNull(ManagedSkillRequest.parse(args(root) + ("expectedGeneration" to -1)))
        assertNull(ManagedSkillRequest.parse(args(root) + ("expectedGeneration" to "1")))
        assertNull(ManagedSkillRequest.parse(args(root) + ("requestId" to "x".repeat(201))))
        assertFalse(dir(root).exists())
    }

    @Test fun utf8BudgetIsCheckedBeforeAnyFileIsCreated() = withRoot { root ->
        val huge = request(root, files = files() + ("large" to "中".repeat(200000)))
        assertEquals("invalid", ManagedSkillInstaller.install(root, huge) { true }.reason)
        assertFalse(dir(root).exists())
    }

    @Test fun escapedFileSymlinkIsNotFollowed() = withRoot { root ->
        val outside = Files.createTempFile("managed-outside-", ".txt").toFile()
        try {
            outside.writeText("mine")
            File(dir(root), "nested").mkdirs()
            Files.createSymbolicLink(File(dir(root), "nested/data.txt").toPath(), outside.toPath())
            assertEquals("userOwned", ManagedSkillInstaller.install(root, request(root)) { true }.result)
            assertEquals("mine", outside.readText())
        } finally { outside.delete() }
    }

    @Test fun cancellationAfterStagingStopsRenameAndSkillIsLast() = withRoot { root ->
        val staged = File(dir(root), "nested/data.txt.dsh-go-tmp")
        val result = ManagedSkillInstaller.install(root, request(root)) { !staged.exists() }
        assertEquals("cancelled", result.reason)
        assertFalse(File(dir(root), "nested/data.txt").exists())
        assertFalse(File(dir(root), "SKILL.md").exists())
        noTemps(root)
        var sawOther = false
        assertEquals("installed", ManagedSkillInstaller.install(root, request(root)) {
            if (File(dir(root), "SKILL.md.dsh-go-tmp").exists()) {
                sawOther = File(dir(root), "nested/data.txt").readText() == "value"
            }
            true
        }.result)
        assertTrue(sawOther)
    }

    @Test fun failureLeavesSkillUnpublishedAndNextRunRepairs() = withRoot { root ->
        File(dir(root), "nested").apply { parentFile!!.mkdirs(); writeText("not a directory") }
        assertEquals("io", ManagedSkillInstaller.install(root, request(root)) { true }.reason)
        assertFalse(File(dir(root), "SKILL.md").exists())
        File(dir(root), "nested").delete()
        assertEquals("installed", ManagedSkillInstaller.install(root, request(root)) { true }.result)
        noTemps(root)
    }

    private class QueueHarness {
        val tasks = ArrayDeque<() -> Unit>()
        val callbacks = ArrayDeque<() -> Unit>()
        val queue = ManagedSkillQueue({ tasks.add(it) }, { callbacks.add(it) })
        val owner = ManagedSkillOwner()
        val results = mutableListOf<Pair<String, Map<String, Any?>>>()
        fun submit(root: File, request: ManagedSkillRequest, owner: ManagedSkillOwner = this.owner, current: () -> Boolean = { true }) {
            queue.submit(owner, request, root, current) { results.add(request.id to it) }
        }
        fun drain() { while (tasks.isNotEmpty()) tasks.removeFirst()(); callbacks() }
        fun callbacks() { while (callbacks.isNotEmpty()) callbacks.removeFirst()() }
    }

    @Test fun oneActiveAndOneLatestPendingStayBoundedDuringBurst() = withRoot { root ->
        val h = QueueHarness()
        h.submit(root, request(root, "active"))
        repeat(100) { h.submit(root, request(root, "pending-$it", files("v$it"))) }
        assertEquals(1, h.tasks.size)
        h.drain()
        assertEquals(101, h.results.size)
        assertEquals(2, h.results.count { it.second["result"] != null })
        assertEquals("v99", File(dir(root), "nested/data.txt").readText())
    }

    @Test fun cancellingActiveDoesNotReleaseItsExecutorSlotBeforeItExits() = withRoot { root ->
        val h = QueueHarness()
        h.submit(root, request(root, "old"))
        h.queue.cancel(h.owner, "old")
        h.submit(root, request(root, "new", files("new")))
        assertEquals(1, h.tasks.size)
        h.drain()
        assertEquals(2, h.results.size)
        assertEquals(false, h.results.first { it.first == "old" }.second["current"])
        assertEquals("new", File(dir(root), "nested/data.txt").readText())
    }

    @Test fun exactCancelDoesNotRetireSuccessorAndResponseIsOnceOnly() = withRoot { root ->
        val h = QueueHarness()
        h.submit(root, request(root, "a")); h.submit(root, request(root, "b", files("b")))
        h.queue.cancel(h.owner, "missing"); h.queue.cancel(h.owner, "a"); h.queue.cancel(h.owner, "a")
        h.drain()
        assertEquals(2, h.results.size)
        assertEquals(true, h.results.first { it.first == "b" }.second["current"])
        assertEquals("b", File(dir(root), "nested/data.txt").readText())
    }

    @Test fun ownerDetachCannotCancelNewEngineWithSameRequestId() = withRoot { root ->
        val h = QueueHarness(); val next = ManagedSkillOwner()
        h.submit(root, request(root, "same")); h.owner.detach(); h.queue.cancel(h.owner)
        h.submit(root, request(root, "same", files("next")), owner = next)
        h.queue.cancel(h.owner, "same"); h.drain()
        assertEquals("next", File(dir(root), "nested/data.txt").readText())
        assertEquals(1, h.results.count { it.second["current"] == true })
    }

    @Test fun duplicateLiveRequestIsRejectedWithoutReusingItsCompletion() = withRoot { root ->
        val h = QueueHarness()
        h.submit(root, request(root)); h.submit(root, request(root)); h.drain()
        assertEquals(2, h.results.size)
        assertEquals(1, h.results.count { it.second["reason"] == "duplicate" })
        assertEquals(1, h.results.count { it.second["result"] == "installed" })
    }

    @Test fun wrongRootResponseIsNotCurrentEvenWhenTheRuntimeStillRuns() = withRoot { root ->
        val h = QueueHarness()
        val wrong = ManagedSkillRequest.parse(args(root) + ("expectedRoot" to File(root, "wrong").path))!!
        h.submit(root, wrong); h.drain()
        assertEquals(false, h.results.single().second["current"])
        assertEquals("stale", h.results.single().second["reason"])
        assertFalse(dir(root).exists())
    }

    @Test fun physicalIoErrorReleasesTheSlotForTheNextBundle() = withRoot { root ->
        val h = QueueHarness()
        File(dir(root), "nested").apply { parentFile!!.mkdirs(); writeText("blocked") }
        h.submit(root, request(root, "fails"))
        h.submit(root, request(root, "next", name = "dsh-go-guide"))
        h.drain()
        assertEquals(2, h.results.size)
        assertEquals("io", h.results.first().second["reason"])
        assertEquals("installed", h.results.last().second["result"])
        assertTrue(File(dir(root, "dsh-go-guide"), "SKILL.md").exists())
    }

    @Test fun runRetirementBeforeWorkerAndBeforeDeliveryAreBothChecked() = withRoot { root ->
        val h = QueueHarness(); var current = true
        h.submit(root, request(root, "queued")) { current }
        current = false; h.drain()
        assertFalse(dir(root).exists())
        current = true
        h.submit(root, request(root, "completed")) { current }
        h.tasks.removeFirst()()
        assertTrue(File(dir(root), "SKILL.md").exists())
        current = false; h.callbacks()
        val result = h.results.last().second
        assertEquals("installed", result["result"])
        assertEquals(false, result["current"])
    }

    @Test fun newRunAndTokenCannotReviveAnOldCapturedScope() {
        val gate = ManagedSkillRuntimeGate(); val owner = ManagedSkillOwner(); gate.attach(owner)
        assertNull(gate.capture(owner, "one", 1))
        gate.ready(1, "one")
        val one = gate.capture(owner, "one", 1)!!
        gate.ready(1, "one")
        assertTrue(gate.current(one)) // repeated status/ready is deduplicated
        gate.ready(2, "two")
        val two = gate.capture(owner, "two", 2)!!
        assertFalse(gate.current(one)); assertNull(gate.capture(owner, "one", 1))
        gate.ready(3, "one")
        assertFalse(gate.current(one)); assertFalse(gate.current(two))
        assertNull(gate.capture(owner, "one", 1)) // same token reused; old incoming call still cannot enter
        assertNotSame(one, gate.capture(owner, "one", 3))
        assertEquals(3L, gate.generationFor("one"))
        gate.ready(1, "one")
        assertEquals(3L, gate.generationFor("one")) // a delayed attach observation cannot rewind a ready run
    }

    @Test fun stopRequestBlocksLateSameRunReadyBeforeServiceStopArrives() {
        val gate = ManagedSkillRuntimeGate(); val owner = ManagedSkillOwner(); gate.attach(owner)
        gate.ready(1, "one"); val one = gate.capture(owner, "one", 1)!!
        gate.stop(1); gate.ready(1, "one")
        assertFalse(gate.current(one)); assertNull(gate.capture(owner, "one", 1))
        gate.ready(2, "two"); val two = gate.capture(owner, "two", 2)!!
        gate.retire() // installing/reset/error or a new start
        assertFalse(gate.current(two)); assertNull(gate.capture(owner, "two", 2))
        gate.ready(3, "three"); assertNotNull(gate.capture(owner, "three", 3))
    }

    @Test fun delayedOldWireCannotBorrowReplacementPluginPermissionInTheSameRun() {
        val gate = ManagedSkillRuntimeGate()
        val old = ManagedSkillOwner(); gate.attach(old); gate.ready(9, "same-token")
        val oldGeneration = gate.generationFor("same-token")!!
        val oldScope = gate.capture(old, "same-token", oldGeneration)!!
        gate.detach(old)
        val next = ManagedSkillOwner(); gate.attach(next); gate.ready(9, "same-token")
        val nextGeneration = gate.generationFor("same-token")!!
        assertNotEquals(oldGeneration, nextGeneration)
        assertFalse(gate.current(oldScope))
        assertNull(gate.capture(next, "same-token", oldGeneration)) // old wire delivered to new handler
        assertNull(gate.capture(old, "same-token", nextGeneration)) // old handler cannot use new status
        assertNotNull(gate.capture(next, "same-token", nextGeneration))
        gate.detach(old) // old detach callback cannot revoke the successor
        assertNotNull(gate.capture(next, "same-token", nextGeneration))
    }

    @Test fun replacementWithoutOldDetachAlsoRetiresThePreviousOwner() {
        val gate = ManagedSkillRuntimeGate()
        val old = ManagedSkillOwner(); gate.attach(old); gate.ready(1, "same")
        val grant = gate.generationFor("same")!!
        val next = ManagedSkillOwner(); assertSame(old, gate.attach(next)); gate.ready(1, "same")
        assertFalse(old.attached)
        assertNull(gate.capture(next, "same", grant))
        assertNotNull(gate.capture(next, "same", gate.generationFor("same")!!))
    }

    @Test fun physicalWriterAndActualRootActivationAreSerialOnSharedWorker() {
        val base = Files.createTempDirectory("managed-activation-").toFile()
        val root = File(base, "rootfs").apply { File(this, "root/.dsh").mkdirs() }
        File(base, "staging/root").mkdirs(); File(base, "staging/new-engine").writeText("new")
        val worker = Executors.newSingleThreadExecutor()
        val staged = CountDownLatch(1); val resume = CountDownLatch(1); val activated = CountDownLatch(1)
        val retired = AtomicBoolean(false); val results = mutableListOf<Map<String, Any?>>()
        val queue = ManagedSkillQueue({ worker.execute(it) }, { it() })
        val owner = ManagedSkillOwner()
        try {
            queue.submit(owner, request(root), root, {
                if (File(dir(root), "nested/data.txt.dsh-go-tmp").exists() && !retired.get()) {
                    staged.countDown(); check(resume.await(5, TimeUnit.SECONDS))
                }
                !retired.get()
            }) { synchronized(results) { results.add(it) } }
            assertTrue(staged.await(5, TimeUnit.SECONDS))
            retired.set(true)
            worker.execute { activateRootfs(base, "new-version", sync = {}); activated.countDown() }
            assertFalse(activated.await(50, TimeUnit.MILLISECONDS))
            resume.countDown()
            assertTrue(activated.await(5, TimeUnit.SECONDS))
            assertEquals("new", File(root, "new-engine").readText())
            assertFalse(File(dir(root), "SKILL.md").exists())
            assertFalse(File(dir(root), "nested/data.txt").exists())
            noTemps(root)
            synchronized(results) { assertEquals(false, results.single()["current"]) }
        } finally {
            resume.countDown(); worker.shutdown(); worker.awaitTermination(5, TimeUnit.SECONDS); base.deleteRecursively()
        }
    }
}
