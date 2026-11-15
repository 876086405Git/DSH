package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File
import java.io.IOException
import java.nio.file.DirectoryIteratorException
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.SecureDirectoryStream
import java.nio.file.attribute.BasicFileAttributeView
import java.nio.file.attribute.BasicFileAttributes

/** PRoot 5.1.107.102 names its private glue directory with the tracer's getpid(). */
internal object ProotTempFiles {
    private val NAME = Regex("proot-([1-9][0-9]*)-[A-Za-z0-9]{6}")

    data class Result(val removed: Int, val incomplete: Boolean)

    /** A failed /proc observation must throw or return false, never mean that a process exited. */
    fun prune(directory: File, isProcessGone: (Int) -> Boolean): Result {
        var removed = 0
        var incomplete = false
        try {
            val path = directory.toPath()
            val parent = path.parent ?: return Result(0, true)
            val expectedParent = Files.readAttributes(parent, BasicFileAttributes::class.java, NOFOLLOW_LINKS)
            if (!expectedParent.isDirectory) return Result(0, true)
            Files.newDirectoryStream(parent).use { opened ->
                // Relative, no-follow operations pin the cache even if a path is replaced during cleanup.
                val cache = opened as? SecureDirectoryStream<Path> ?: return Result(0, true)
                if (!sameDirectory(expectedParent, cache.attributes())) return Result(0, true)
                cache.newDirectoryStream(path.fileName, NOFOLLOW_LINKS).use { temp ->
                    for (entry in temp) {
                        val name = entry.fileName
                        val pid = NAME.matchEntire(name.toString())?.groupValues?.get(1)?.toIntOrNull() ?: continue
                        try {
                            val expected = temp.attributes(name)
                            if (!expected.isDirectory || expected.fileKey() == null) continue
                            val emptied = temp.newDirectoryStream(name, NOFOLLOW_LINKS).use { child ->
                                if (!sameDirectory(expected, child.attributes()) ||
                                    !runCatching { isProcessGone(pid) }.getOrDefault(false) ||
                                    !sameDirectory(expected, temp.attributes(name))) false
                                else {
                                    clear(child)
                                    true
                                }
                            }
                            if (emptied && sameDirectory(expected, temp.attributes(name))) {
                                temp.deleteDirectory(name)
                                removed++
                            }
                        } catch (_: NoSuchFileException) {
                            // PRoot or another cleanup already removed this entry.
                        } catch (_: IOException) {
                            incomplete = true
                        } catch (_: SecurityException) {
                            incomplete = true
                        }
                    }
                }
            }
        } catch (_: NoSuchFileException) {
            // No temporary store to reclaim.
        } catch (_: IOException) {
            incomplete = true
        } catch (_: SecurityException) {
            incomplete = true
        } catch (_: UnsupportedOperationException) {
            incomplete = true
        } catch (_: DirectoryIteratorException) {
            incomplete = true
        }
        return Result(removed, incomplete)
    }

    private fun sameDirectory(expected: BasicFileAttributes, actual: BasicFileAttributes): Boolean =
        expected.isDirectory && actual.isDirectory && expected.fileKey() != null && expected.fileKey() == actual.fileKey()

    private fun SecureDirectoryStream<Path>.attributes(name: Path? = null): BasicFileAttributes =
        (if (name == null) getFileAttributeView(BasicFileAttributeView::class.java)
        else getFileAttributeView(name, BasicFileAttributeView::class.java, NOFOLLOW_LINKS)).readAttributes()

    private fun clear(directory: SecureDirectoryStream<Path>) {
        for (entry in directory) {
            val name = entry.fileName
            val expected = directory.attributes(name)
            if (expected.isDirectory) {
                directory.newDirectoryStream(name, NOFOLLOW_LINKS).use { child ->
                    if (!sameDirectory(expected, child.attributes())) throw IOException("temporary directory changed")
                    clear(child)
                }
                if (!sameDirectory(expected, directory.attributes(name))) throw IOException("temporary directory changed")
                directory.deleteDirectory(name)
            } else {
                // This also unlinks dangling symlinks; their targets are never opened or chmodded.
                directory.deleteFile(name)
            }
        }
    }
}
