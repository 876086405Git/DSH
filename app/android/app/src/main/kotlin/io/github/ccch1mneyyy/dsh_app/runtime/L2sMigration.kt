package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File
import java.io.IOException
import java.nio.file.FileVisitResult
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.Paths
import java.nio.file.SimpleFileVisitor
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.BasicFileAttributes
import java.security.SecureRandom

/**
 * Turns PRoot's fake hard links into real files, so an install that ran under
 * PRoot can launch directly. PRoot's --link2symlink (Termux 5.1.107.102, with
 * PROOT_L2S_DIR={ROOTFS}/root/.l2s) moves a file that gets a second name into
 * that store as `.l2s.<name><NNNN>.<MMMM>`, MMMM being its link count, and
 * leaves symlinks with host-absolute targets: the intermediate
 * `.l2s.<name><NNNN>` to the stored file, and every name to the intermediate.
 *
 * For each stored file with names N1..Nk, N1..Nk-1 get a copy (mode and mtime
 * kept) renamed over them, then the stored file itself is renamed over Nk.
 * Each step is one rename, so every name keeps reading the same content and a
 * killed run resumes on the next start. PRoot also keeps working on a
 * half-done tree: it only lowers a count when a name that is still its symlink
 * goes away, and converting a name never lowers it, so a stored file outlives
 * every symlink that still needs it (at worst it stays as an orphan, removed
 * here next time).
 *
 * [flush] makes the copies durable before any of them replaces a name.
 * [guestBinds] are the guest paths PRoot binds over ([bindTargets]): there the
 * guest sees the host, so nothing under them in the rootfs is a PRoot name.
 * [within] copies only that reset item, keeping every store entry for other
 * names. [relocatedStore] is its actual store after retirement or home.carry;
 * rootfs still identifies the original host-absolute targets.
 */
class L2sMigration(
    rootfs: File,
    private val flush: () -> Unit,
    private val freeBytes: () -> Long = { rootfs.usableSpace },
    guestBinds: Collection<String> = emptyList(),
    private val within: File? = null,
    relocatedStore: File? = null,
) {
    sealed class Result {
        /** [links] names became real files; [removed] store entries nothing named any more. */
        data class Done(val links: Int, val removed: Int) : Result()
        data class NotEnoughSpace(val need: Long, val free: Long) : Result()
    }

    private class Group(val stored: Path, val names: MutableList<Path> = ArrayList(), val chain: MutableSet<Path> = HashSet())

    private val root = rootfs.canonicalFile.toPath()
    private val rootPath = root.toString()
    private val originalStore = root.resolve("root/.l2s")
    private val store = relocatedStore?.toPath()?.toAbsolutePath()?.normalize() ?: originalStore
    private val random = SecureRandom()
    private val binds: Set<Path> = guestBinds.filter { it.startsWith("/") }
        .map { root.resolve(it.trimStart('/')).normalize() }
        .filter { it.startsWith(root) && it != root }
        .toSet()

    /**
     * Throws on any IO error, leaving every name readable; the next run picks
     * up from there. [onSlow] runs once when this takes more than a moment.
     * [beforeRename] is a test seam for interrupting the run.
     */
    fun run(onSlow: () -> Unit = {}, beforeRename: () -> Unit = {}): Result {
        // A symlinked store would point the deletions below somewhere else.
        val hasStore = Files.isDirectory(store, LinkOption.NOFOLLOW_LINKS)
        if (!hasStore && within == null) return Result.Done(0, 0)
        val started = System.nanoTime()
        var slow = false
        fun tick() {
            if (!slow && System.nanoTime() - started > SLOW_NANOS) { slow = true; onSlow() }
        }

        val groups = LinkedHashMap<Path, Group>()
        // An unreadable bind ancestor or a damaged store chain can hide references.
        // In that case keep all leftovers instead of declaring them orphaned.
        var keepOrphans = false
        // Every name lies in the rootfs: PRoot moves a file into the store by rename, so a
        // file elsewhere (/sdcard, /storage) never becomes a fake link. Other unreadable
        // directories abort the walk: a name missed there would make its file look orphaned.
        val start = within?.toPath()?.toAbsolutePath()?.normalize() ?: root
        Files.walkFileTree(start, object : SimpleFileVisitor<Path>() {
            override fun preVisitDirectory(dir: Path, attrs: BasicFileAttributes) =
                if (dir == store || dir in binds) FileVisitResult.SKIP_SUBTREE else FileVisitResult.CONTINUE

            // The directory is opened before preVisitDirectory: an unreadable one lands here.
            override fun visitFileFailed(file: Path, exc: IOException): FileVisitResult {
                // PRoot's placeholder for a bind (system, apex on Android 16 can't be listed).
                if (file in binds) return FileVisitResult.CONTINUE
                if (binds.any { it.startsWith(file) }) { keepOrphans = true; return FileVisitResult.CONTINUE }
                throw exc
            }

            override fun visitFile(file: Path, attrs: BasicFileAttributes): FileVisitResult {
                tick()
                if (attrs.isSymbolicLink) {
                    val destination = target(file)
                    val through = if (hasStore) chain(destination) else null
                    if (through != null) groups.getOrPut(through.last()) { Group(through.last()) }.apply {
                        names.add(file)
                        chain += through.dropLast(1)
                    } else if (destination.parent == store) {
                        // Older resets could already have deleted this name's first hop.
                        // A present but broken chain may still have recoverable contents.
                        if (within != null && !Files.notExists(destination, LinkOption.NOFOLLOW_LINKS)) {
                            throw IOException("could not resolve PRoot link: $file")
                        }
                        // A damaged PRoot chain can leave its content under a new
                        // count suffix. It is not safe to call that file an orphan.
                        keepOrphans = true
                    }
                } else if (attrs.isRegularFile && TEMP.matches(file.fileName.toString())) {
                    Files.delete(file) // a copy from a run that was killed before its rename
                }
                return FileVisitResult.CONTINUE
            }
        })

        // Reset keeps only the selected files; actual copy failures remain retryable.
        // The full-launch spare-space requirement must not block a small kept item.
        if (within == null) {
            val need = groups.values.sumOf { blocks(Files.size(it.stored)) * (it.names.size - 1) }
            if (need > 0) {
                val free = freeBytes()
                if (free < need + MARGIN) return Result.NotEnoughSpace(need, free)
            }
        }

        var links = 0
        val batch = ArrayList<Group>()
        var files = 0
        var bytes = 0L
        fun copyNames(group: Group) = if (within == null) group.names.dropLast(1) else group.names
        fun commit() {
            val copies = ArrayList<Pair<Path, Path>>()
            var renamed = 0
            try {
                for (group in batch) for (name in copyNames(group)) {
                    tick()
                    val temp = name.resolveSibling(TEMP_PREFIX + "%016x".format(random.nextLong()) + ".tmp")
                    Files.copy(group.stored, temp, StandardCopyOption.COPY_ATTRIBUTES)
                    copies += temp to name
                }
                if (copies.isNotEmpty()) flush()
                for (group in batch) {
                    repeat(copyNames(group).size) {
                        val (temp, name) = copies[renamed]
                        beforeRename()
                        Files.move(temp, name, StandardCopyOption.ATOMIC_MOVE)
                        renamed++
                        links++
                    }
                    if (within == null) {
                        beforeRename()
                        Files.move(group.stored, group.names.last(), StandardCopyOption.ATOMIC_MOVE)
                        links++
                        // Right away: PRoot takes a dangling intermediate's name as free for a new
                        // link, then fails to create it after it already moved that file in.
                        for (entry in group.chain) Files.deleteIfExists(entry)
                    }
                }
            } finally {
                for (at in renamed until copies.size) runCatching { Files.deleteIfExists(copies[at].first) }
            }
            batch.clear()
            files = 0
            bytes = 0L
        }
        for (group in groups.values.sortedBy { it.stored }) {
            group.names.sort()
            batch += group
            files += copyNames(group).size
            bytes += blocks(Files.size(group.stored)) * copyNames(group).size
            if (files >= BATCH_FILES || bytes >= BATCH_BYTES) commit()
        }
        commit()
        if (within != null) return Result.Done(links, 0)

        // What is left was named by nothing: intermediates of files removed outside PRoot,
        // files whose names were all deleted without it. Symlinks first, for the same reason
        // as above. Directories are not PRoot's; they stay, and so does compatible launch.
        if (keepOrphans) return Result.Done(links, 0)
        val left = Files.newDirectoryStream(store).use { it.toList() }
            .filterNot { Files.isDirectory(it, LinkOption.NOFOLLOW_LINKS) }
            .sortedByDescending { Files.isSymbolicLink(it) }
        for (entry in left) Files.deleteIfExists(entry)
        return Result.Done(links, left.size)
    }

    /** The store entries starting at [first], ending with the stored file; null if not a complete store chain. */
    private fun chain(first: Path): List<Path>? {
        val chain = ArrayList<Path>()
        var entry = first
        while (entry.parent == store && chain.size < MAX_HOPS) {
            chain.add(entry)
            val attrs = try {
                Files.readAttributes(entry, BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
            } catch (_: NoSuchFileException) { return null }
            if (attrs.isRegularFile) return chain
            if (!attrs.isSymbolicLink) return null
            entry = target(entry)
        }
        return null
    }

    /** Where PRoot resolves [link]: an absolute target inside the rootfs is a host path, any other a guest path. */
    private fun target(link: Path): Path {
        val value = Files.readSymbolicLink(link).toString()
        val destination = when {
            !value.startsWith("/") -> link.resolveSibling(value)
            value == rootPath || value.startsWith("$rootPath/") -> Paths.get(value)
            else -> Paths.get(rootPath + value)
        }.normalize()
        return if (destination.parent == originalStore) store.resolve(destination.fileName) else destination
    }

    companion object {
        const val TEMP_PREFIX = ".dsh-go-l2s-"
        val TEMP = Regex("""\.dsh-go-l2s-[0-9a-f]{16}\.tmp""")
        /** Kept free beyond the copies, for the engine itself. */
        const val MARGIN = 128L shl 20
        private const val SLOW_NANOS = 500_000_000L
        private const val MAX_HOPS = 40
        private const val BATCH_FILES = 2000
        private const val BATCH_BYTES = 256L shl 20

        private fun blocks(size: Long) = 4096 + (size + 4095) / 4096 * 4096

        /** Guest paths of the PRoot `-b host[:guest]` binds in [prootArgv] (before the guest command) and [extra]. */
        fun bindTargets(prootArgv: List<String>, extra: List<String>): List<String> {
            val end = prootArgv.indexOf("/usr/bin/env").let { if (it < 0) prootArgv.size else it }
            val specs = (1 until end).filter { prootArgv[it - 1] == "-b" || prootArgv[it - 1] == "--bind" }.map { prootArgv[it] }
            return (specs + extra).map { it.substringAfter(':') }
        }
    }
}
