package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File
import java.io.FileOutputStream
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardCopyOption.REPLACE_EXISTING
import java.nio.file.StandardOpenOption

/** An upgrade must never fall back to rebuilding an existing user system. */
internal class RuntimeUpgradeBlocked(reason: String) : IllegalStateException("runtime_upgrade_blocked:$reason")

internal val ENGINE_PATHS = listOf(
    "opt/dsh", "opt/node", "opt/dsh-go", "etc/dsh-app",
    "etc/profile.d/dsh-app.sh", "usr/local/lib/node_modules/pnpm",
    "usr/local/bin/dsh", "usr/local/bin/node", "usr/local/bin/npm", "usr/local/bin/npx",
    "usr/local/bin/corepack", "usr/local/bin/pnpm", "usr/local/bin/pnpx", "usr/local/bin/pn", "usr/local/bin/pnx",
)

internal data class EngineUpgradeSpec(val baseId: String, val ubuntuVersion: String, val paths: List<String>) {
    fun validate() {
        if (!baseId.matches(Regex("[a-f0-9]{64}")) || ubuntuVersion.isBlank() || paths != ENGINE_PATHS) {
            throw RuntimeUpgradeBlocked("manifest")
        }
    }
}

/**
 * A forward-only, durable transaction. Its new payload and old engine are outside
 * staging, which install may discard. User files never enter the transaction.
 * A killed install resumes before staging is touched, even across APK versions.
 */
internal class EngineUpgrade(
    private val base: File,
    private val sync: () -> Unit,
    private val syncDirectory: (File) -> Unit = { dir ->
        FileChannel.open(dir.toPath(), StandardOpenOption.READ).use { it.force(true) }
    },
    private val afterStep: (String) -> Unit = {},
) {
    private val root = File(base, "rootfs")
    private val pending = File(base, "engine.upgrade")
    private val preparing = File(base, "engine.prepare")
    private val done = File(base, "engine.done")
    private val marker = File(base, "rootfs.version")

    fun isPending(): Boolean = present(pending)

    /** Old payload from a committed upgrade; never resumes or discards an unfinished one. */
    fun cleanupCommitted() = remove(done)

    fun activate(version: String, spec: EngineUpgradeSpec) {
        spec.validate()
        validateVersion(version)
        recover()
        val staging = File(base, "staging")
        // Validate every path before the first mutation of the active tree.
        for (path in spec.paths) {
            safePath(root, path)
            val source = safePath(staging, path)
            if (!present(source)) throw RuntimeUpgradeBlocked("payload")
        }
        remove(preparing)
        check(preparing.mkdirs()) { "could not prepare engine upgrade" }
        for (path in spec.paths) {
            val target = safePath(File(preparing, "new"), path)
            ensureParent(target)
            move(safePath(staging, path), target)
        }
        writeSynced(File(preparing, "version"), version)
        writeSynced(File(preparing, "original"), spec.paths.filter { present(File(root, it)) }.joinToString("\n"))
        sync()
        afterStep("prepared")
        move(preparing, pending)
        afterStep("journal")
        recover()
    }

    /** The version completed by this call, or null when no published journal needed recovery. */
    fun recover(): String? {
        // Committed transactions are retired atomically before their cleanup.
        cleanupCommitted()
        if (!present(pending)) {
            remove(preparing)
            return null
        }
        if (!Files.isDirectory(pending.toPath(), NOFOLLOW_LINKS)) throw RuntimeUpgradeBlocked("transaction")
        val version = try { File(pending, "version").readText() }
            catch (_: Exception) { throw RuntimeUpgradeBlocked("transaction") }
        validateVersion(version)
        val original = try { File(pending, "original").readLines() }
            catch (_: Exception) { throw RuntimeUpgradeBlocked("transaction") }
        if (original.distinct() != original || original.any { it !in ENGINE_PATHS }) {
            throw RuntimeUpgradeBlocked("transaction")
        }
        for (path in ENGINE_PATHS) {
            safePath(root, path)
            safePath(File(pending, "new"), path)
            safePath(File(pending, "old"), path)
        }
        if (Files.deleteIfExists(marker.toPath())) syncDirectory(base)
        afterStep("retired")
        for (path in ENGINE_PATHS) {
            val target = safePath(root, path)
            val next = safePath(File(pending, "new"), path)
            val old = safePath(File(pending, "old"), path)
            if (present(next)) {
                if (present(target) && !present(old)) {
                    ensureParent(old)
                    move(target, old)
                    afterStep("backup:$path")
                }
                // With an old copy already present, target can only be the new
                // entry from an interrupted rename. Do not delete unknown data.
                if (present(target)) throw RuntimeUpgradeBlocked("transaction")
                ensureParent(target)
                move(next, target)
                afterStep("activate:$path")
            } else if (!present(target) || (path in original && !present(old))) {
                throw RuntimeUpgradeBlocked("transaction")
            }
        }
        sync()
        afterStep("data")
        publishRuntimeVersion(base, version, syncDirectory)
        afterStep("marker")
        move(pending, done)
        afterStep("committed")
        cleanupCommitted()
        return version
    }

    private fun ensureParent(file: File) {
        val missing = mutableListOf<File>()
        var directory = file.parentFile!!
        while (!present(directory)) {
            missing += directory
            directory = directory.parentFile ?: throw RuntimeUpgradeBlocked("layout")
        }
        for (next in missing.asReversed()) {
            Files.createDirectory(next.toPath())
            syncDirectory(next)
            syncDirectory(next.parentFile!!)
        }
    }

    private fun move(from: File, to: File) {
        check(from.renameTo(to)) { "could not move engine upgrade entry" }
        // Persist the destination before the source removal: a power cut must
        // not make an entry unreachable from both sides of a cross-dir rename.
        syncDirectory(to.parentFile!!)
        if (from.parentFile != to.parentFile) syncDirectory(from.parentFile!!)
    }

    private fun validateVersion(version: String) {
        if (!version.matches(Regex("[A-Za-z0-9._-]+"))) throw RuntimeUpgradeBlocked("transaction")
    }

    private fun present(file: File): Boolean = Files.exists(file.toPath(), NOFOLLOW_LINKS)

    private fun safePath(tree: File, relative: String): File {
        // Managed leaf symlinks are moved as links, never followed. A user's
        // symlinked parent must not redirect an upgrade outside the system.
        var parent: File? = File(tree, relative).parentFile
        while (parent != null) {
            if (Files.isSymbolicLink(parent.toPath())) throw RuntimeUpgradeBlocked("symlink")
            if (present(parent) && !Files.isDirectory(parent.toPath(), NOFOLLOW_LINKS)) {
                throw RuntimeUpgradeBlocked("layout")
            }
            if (parent == tree) break
            parent = parent.parentFile
        }
        return File(tree, relative)
    }

    private fun remove(file: File) {
        if (!present(file)) return
        if (Files.isDirectory(file.toPath(), NOFOLLOW_LINKS)) {
            for (child in file.listFiles() ?: throw IllegalStateException("could not list engine transaction")) remove(child)
        }
        Files.delete(file.toPath())
    }
}

/** Publish only a complete marker, after its caller has synced the runtime data. */
internal fun publishRuntimeVersion(base: File, version: String, syncDirectory: (File) -> Unit) {
    val temporary = File(base, "rootfs.version.next")
    Files.deleteIfExists(temporary.toPath())
    writeSynced(temporary, version)
    Files.move(temporary.toPath(), File(base, "rootfs.version").toPath(), ATOMIC_MOVE, REPLACE_EXISTING)
    syncDirectory(base)
}

private fun writeSynced(file: File, text: String) {
    FileOutputStream(file).use { out -> out.write(text.toByteArray(Charsets.UTF_8)); out.fd.sync() }
}
