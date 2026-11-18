package io.github.ccch1mneyyy.dsh_app.runtime

import io.github.ccch1mneyyy.dsh_app.files.GuestFiles
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardCopyOption

/** A Flutter engine attachment, independent of Activity detach/reattach. */
internal class ManagedSkillOwner {
    @Volatile var attached = true
        private set

    fun detach() { attached = false }
}

/** Observed runtime readiness and its attachment permission; never a launcher. */
internal class ManagedSkillRuntimeGate {
    internal class Scope(val owner: ManagedSkillOwner, val runtimeGeneration: Int, val token: String, val generation: Long)
    private data class Ready(val runtimeGeneration: Int, val token: String)
    @Volatile private var active: Scope? = null
    private var owner: ManagedSkillOwner? = null
    // A real onReady can precede attachment or still be publishing RUNNING. Preserve
    // that fact independently of the owner, but never across runtime retirement.
    private var confirmed: Ready? = null
    private var stoppedGeneration = -1
    private var latestRuntimeGeneration = -1
    private var serial = 0L

    /** Only the latest Flutter attachment may install. Old handlers cannot borrow its grant. */
    @Synchronized fun attach(next: ManagedSkillOwner): ManagedSkillOwner? {
        val previous = owner
        previous?.detach()
        owner = next
        active = null
        grantReady()
        return previous
    }

    @Synchronized fun detach(previous: ManagedSkillOwner) {
        previous.detach()
        if (owner === previous) { owner = null; active = null }
    }

    @Synchronized fun ready(generation: Int, token: String) {
        if (generation <= stoppedGeneration || generation < latestRuntimeGeneration) return
        latestRuntimeGeneration = generation
        confirmed = Ready(generation, token)
        grantReady()
    }

    /** Caller holds this monitor. No IO, callbacks, or Controller lock acquisition. */
    private fun grantReady() {
        val ready = confirmed ?: return
        val attached = owner?.takeIf { it.attached } ?: return
        val previous = active
        if (previous == null || previous.owner !== attached ||
            previous.runtimeGeneration != ready.runtimeGeneration || previous.token != ready.token) {
            active = null
            if (serial == Long.MAX_VALUE) return // never wrap into an earlier grant
            active = Scope(attached, ready.runtimeGeneration, ready.token, ++serial)
        }
    }

    @Synchronized fun stop(generation: Int) {
        stoppedGeneration = maxOf(stoppedGeneration, generation)
        confirmed = null
        active = null
    }

    @Synchronized fun retire() { confirmed = null; active = null }
    fun generationFor(token: String?): Long? = active?.takeIf { it.owner.attached && it.token == token }?.generation
    fun capture(owner: ManagedSkillOwner, expectedToken: String, expectedGeneration: Long): Scope? = active?.takeIf {
        it.owner === owner && owner.attached && it.token == expectedToken && it.generation == expectedGeneration
    }
    fun current(scope: Scope): Boolean = active === scope && scope.owner.attached
}

/** Only the app's bundled skills use this private channel. Never log its arguments. */
internal class ManagedSkillRequest private constructor(
    val id: String,
    val expectedRoot: String,
    val expectedToken: String,
    val expectedGeneration: Long,
    val name: String,
    val files: Map<String, String>,
) {
    companion object {
        const val MAX_FILES = 64
        const val MAX_FILE_BYTES = 512 * 1024
        const val MAX_BYTES = 1024 * 1024
        private val names = setOf("dsh-go-ui", "dsh-go-plugin", "dsh-go-guide", "dsh-go-support", "companion-adapt", "pet-theme")
        private val path = Regex("^[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*$")

        /** Cheap bounded checks on the main thread; UTF-8 encoding happens on the runtime worker. */
        fun parse(raw: Any?): ManagedSkillRequest? {
            val args = raw as? Map<*, *> ?: return null
            val id = args["requestId"] as? String ?: return null
            val root = args["expectedRoot"] as? String ?: return null
            val token = args["expectedToken"] as? String ?: return null
            val generation = when (val value = args["expectedGeneration"]) {
                is Int -> value.toLong()
                is Long -> value
                else -> return null
            }
            val name = args["name"] as? String ?: return null
            val files = args["files"] as? Map<*, *> ?: return null
            if (id.isEmpty() || id.length > 200 || root.isEmpty() || root.length > 4096 ||
                token.isEmpty() || token.length > 4096 || generation < 1 || name !in names || files.size !in 1..MAX_FILES) return null
            val checked = LinkedHashMap<String, String>()
            var units = 0
            for ((key, value) in files) {
                if (key !is String || key.length > 512 || !path.matches(key) || value !is String ||
                    value.length > MAX_FILE_BYTES) return null
                units += value.length
                if (units > MAX_BYTES) return null
                checked[key] = value
            }
            if (!checked.containsKey("SKILL.md")) return null
            return ManagedSkillRequest(id, root, token, generation, name, checked)
        }
    }
}

internal data class ManagedSkillOutcome(val result: String? = null, val reason: String? = null)

/**
 * File transaction on RuntimeController's worker, also used by rootfs activation/reset.
 * Cancellation stops later commits. An already-started filesystem operation can finish;
 * it is not rollback. SKILL.md is committed last so a first partial install stays hidden.
 */
internal object ManagedSkillInstaller {
    private const val MARKER = "# dsh-go:managed"
    private val frontMatter = Regex("^---\\r?\\n([\\s\\S]*?)\\r?\\n---")

    private fun managed(text: String): Boolean = frontMatter.find(text)?.groupValues?.get(1)
        ?.lineSequence()?.any { it.trimStart().startsWith(MARKER) } == true

    fun install(root: File, request: ManagedSkillRequest, current: () -> Boolean): ManagedSkillOutcome {
        fun checkCurrent() { if (!current()) throw Retired() }
        try {
            checkCurrent()
            if (File(request.expectedRoot).canonicalFile != root.canonicalFile) return ManagedSkillOutcome(reason = "stale")
            val bytes = LinkedHashMap<String, ByteArray>()
            var total = 0
            for ((path, text) in request.files) {
                val encoder = Charsets.UTF_8.newEncoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                val encoded = encoder.encode(java.nio.CharBuffer.wrap(text))
                val data = ByteArray(encoded.remaining()).also { encoded.get(it) }
                total += data.size
                if (data.size > ManagedSkillRequest.MAX_FILE_BYTES || total > ManagedSkillRequest.MAX_BYTES) {
                    return ManagedSkillOutcome(reason = "invalid")
                }
                bytes[path] = data
            }
            if (!managed(request.files.getValue("SKILL.md"))) return ManagedSkillOutcome(reason = "invalid")
            checkCurrent()
            val home = File(root, "root/.dsh")
            if (!home.isDirectory) return ManagedSkillOutcome("noHome")
            val dir = File(home, "skills/${request.name}")
            val rootPath = root.canonicalFile.toPath()
            val dirPath = dir.canonicalFile.toPath()
            // Fail closed for an escaped managed directory/file. This is not a sandbox against
            // another writer changing symlinks concurrently; rootfs swaps are serialized above.
            if (!dirPath.startsWith(rootPath)) return ManagedSkillOutcome("userOwned")
            for (path in bytes.keys) {
                if (!File(dir, path).canonicalFile.toPath().startsWith(dirPath) ||
                    !File(dir, "$path.dsh-go-tmp").canonicalFile.toPath().startsWith(dirPath)) {
                    return ManagedSkillOutcome("userOwned")
                }
            }
            val skill = File(dir, "SKILL.md")
            val existed = Files.exists(skill.toPath(), LinkOption.NOFOLLOW_LINKS)
            if (existed && readText(root, skill, ManagedSkillRequest.MAX_FILE_BYTES)?.let(::managed) != true) {
                return ManagedSkillOutcome("userOwned")
            }
            var changed = false
            val order = bytes.keys.filter { it != "SKILL.md" } + "SKILL.md"
            for (path in order) {
                checkCurrent()
                val file = File(dir, path)
                val data = bytes.getValue(path)
                if (readText(root, file, data.size + 3) == request.files.getValue(path)) continue
                checkCurrent()
                val parent = file.parentFile!!
                if (!parent.isDirectory && !parent.mkdirs() && !parent.isDirectory) {
                    throw java.io.IOException("cannot create skill directory")
                }
                val tmp = File(parent, "${file.name}.dsh-go-tmp")
                try {
                    checkCurrent()
                    FileOutputStream(tmp).use { stream -> stream.write(data); stream.fd.sync() }
                    checkCurrent()
                    Files.move(tmp.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
                    changed = true
                } finally {
                    // A failed/retired stage must not poison the next run's managed install.
                    if (tmp.exists()) tmp.delete()
                }
            }
            return ManagedSkillOutcome(if (!existed) "installed" else if (changed) "updated" else "unchanged")
        } catch (_: Retired) {
            return ManagedSkillOutcome(reason = "cancelled")
        } catch (_: Exception) {
            // No file contents, token, path or filesystem error text crosses into runtime logs.
            return ManagedSkillOutcome(reason = "io")
        }
    }

    /** Bounded, strict UTF-8, with the same leading-BOM behavior as Dart File.readAsString. */
    private fun readText(root: File, file: File, limit: Int): String? = try {
        // tawc hard links are unreadable to Android; resolve their bytes only.
        // Writes still replace the original name, leaving a hard-link backup intact.
        // /sdcard is also Android's primary-storage alias.
        val source = file.takeIf { it.isFile } ?: GuestFiles.resolve(
            root, "/${file.relativeTo(root).invariantSeparatorsPath}", phoneRoot = PhoneStorage.GUEST_PATH,
        )
        source?.inputStream()?.use { stream ->
            val out = ByteArrayOutputStream(minOf(limit, 8192))
            val buffer = ByteArray(8192)
            while (true) {
                val count = stream.read(buffer, 0, minOf(buffer.size, limit + 1 - out.size()))
                if (count < 0) break
                out.write(buffer, 0, count)
                if (out.size() > limit) return null
            }
            val decoder = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
            decoder.decode(ByteBuffer.wrap(out.toByteArray())).toString().removePrefix("\uFEFF")
        }
    } catch (_: Exception) { null }

    private class Retired : RuntimeException()
}

/**
 * One active and one latest pending request, across all engine attachments. The active
 * slot is held until physical work exits even if its caller cancels. Never run file IO
 * or callbacks under [lock]; enqueue each successor separately on the same runtime worker.
 */
internal class ManagedSkillQueue(
    private val execute: (() -> Unit) -> Unit,
    private val deliver: (() -> Unit) -> Unit,
) {
    private val lock = Any()
    private var active: Job? = null
    private var pending: Job? = null

    // Callback delivery retains this small permission record, not a cancelled
    // pending request's up-to-1MiB bundle. Physical work still retains its slot.
    private class Permission(val owner: ManagedSkillOwner, val scopeCurrent: () -> Boolean) {
        @Volatile var cancelled = false
        fun current() = !cancelled && owner.attached && scopeCurrent()
    }

    private class Job(
        val owner: ManagedSkillOwner,
        val request: ManagedSkillRequest,
        val root: File,
        scopeCurrent: () -> Boolean,
        val callback: (Map<String, Any?>) -> Unit,
    ) {
        val permission = Permission(owner, scopeCurrent)
        var responded = false // guarded by queue.lock
        fun current() = permission.current()
    }

    fun submit(
        owner: ManagedSkillOwner, request: ManagedSkillRequest, root: File,
        current: () -> Boolean, onDone: (Map<String, Any?>) -> Unit,
    ) {
        val job = Job(owner, request, root, current, onDone)
        if (!job.current()) { respond(job, ManagedSkillOutcome(reason = "stale")); return }
        var replaced: Job? = null
        var start = false
        val duplicate: Boolean
        synchronized(lock) {
            duplicate = listOfNotNull(active, pending).any { it.owner === owner && it.request.id == request.id }
            if (!duplicate) {
                if (active == null) { active = job; start = true }
                else { replaced = pending; pending = job; replaced?.permission?.cancelled = true }
            }
        }
        if (duplicate) { respond(job, ManagedSkillOutcome(reason = "duplicate")); return }
        replaced?.let { respond(it, ManagedSkillOutcome(reason = "cancelled")) }
        if (start) schedule(job)
    }

    fun cancel(owner: ManagedSkillOwner, requestId: String? = null) {
        val retired = synchronized(lock) {
            listOfNotNull(active, pending).filter { it.owner === owner && (requestId == null || it.request.id == requestId) }
                .also { jobs ->
                    jobs.forEach { it.permission.cancelled = true }
                    if (pending in jobs) pending = null
                }
        }
        retired.forEach { respond(it, ManagedSkillOutcome(reason = "cancelled")) }
    }

    private fun schedule(job: Job) {
        execute {
            try {
                respond(job, ManagedSkillInstaller.install(job.root, job.request, job::current))
            } finally {
                val next = synchronized(lock) {
                    if (active === job) { active = pending; pending = null; active } else null
                }
                if (next != null) schedule(next)
            }
        }
    }

    private fun respond(job: Job, outcome: ManagedSkillOutcome) {
        val first = synchronized(lock) { if (job.responded) false else { job.responded = true; true } }
        if (!first) return
        val permission = job.permission
        val callback = job.callback
        deliver {
            val current = permission.current() && outcome.reason != "stale" && outcome.reason != "cancelled"
            callback(mapOf("result" to outcome.result, "current" to current,
                "reason" to (if (!current) "stale" else outcome.reason)))
        }
    }
}
