package io.github.ccch1mneyyy.dsh_app.phone.skills

import io.github.ccch1mneyyy.dsh_app.phone.Json
import java.io.File
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.DirectoryNotEmptyException
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardCopyOption.REPLACE_EXISTING
import java.nio.file.StandardOpenOption.WRITE
import java.security.MessageDigest
import java.util.UUID

/** Access on RuntimeController's serialized rootfs worker. No task or registry lock crosses IO.
 * Only the app-private record is authoritative. An app-private staged publication is replayed
 * after interruption; a conflicting independently edited guest document is never silently replaced. */
internal class PhoneSkillStore(
    rootfs: File, privateDir: File,
    private val clean: (PhoneSkillDocument) -> PhoneSkillDocument,
    private val cleanLegacy: (String) -> String,
    private val now: () -> Long = System::currentTimeMillis,
) {
    private val root = rootfs.canonicalFile.toPath()
    private val privateRoot = privateDir.toPath().toAbsolutePath().normalize()
    private val records get() = directory(directory(privateRoot).resolve("records"))
    private val pendingFile get() = directory(privateRoot).resolve("drafts.json")
    private val skills: Path get() {
        val home = root.resolve("root/.dsh")
        if (!Files.isDirectory(home, NOFOLLOW_LINKS) || home.toFile().canonicalFile.toPath() != home)
            throw IOException("Skill home is unavailable.")
        return directory(home.resolve("skills"))
    }

    private data class Version(val at: Long, val body: String) {
        fun disk() = mapOf("at" to at, "body" to body)
    }

    private data class Record(val name: String, val body: String?, val status: PhoneSkillStatus, val updated: Long,
        val versions: List<Version>, val previous: String? = null, val statusOnly: Boolean = false) {
        fun disk() = mapOf("body" to body, "status" to status.toMap(), "updated" to updated,
            "versions" to versions.map { it.disk() }, "previous" to previous, "statusOnly" to statusOnly)
    }

    fun list(): PhoneSkillListing {
        val names = children(records).map { it.fileName.toString() }
            .filter { it.endsWith(".json") || it.endsWith(".pending") }
            .map { it.substringBeforeLast('.') }.filter(PhoneSkillDocument::validName).distinct()
        val managed = names.sorted().mapNotNull(::load)
        val saved = managed.filter { it.body != null }.map(::saved)
        val archived = managed.filter { it.body == null && it.versions.isNotEmpty() }.map { it.name }
        val legacy = children(skills).mapNotNull { path ->
            val name = path.fileName.toString()
            if (!PhoneSkillDocument.legacyName.matches(name) || !Files.isDirectory(path, NOFOLLOW_LINKS) ||
                !Files.isRegularFile(path.resolve("SKILL.md"), NOFOLLOW_LINKS)) return@mapNotNull null
            mapOf("name" to name, "path" to "skills/" + name + "/SKILL.md")
        }.sortedBy { it.getValue("name") }
        return PhoneSkillListing(saved, drafts(), legacy, archived)
    }

    /** Suppress unconfirmed same-prefix files in the engine provider without adopting their bytes. */
    fun quarantined(accepted: Set<String>): List<String> = children(skills).map { it.fileName.toString() }
        .filter { PhoneSkillDocument.validName(it) && it !in accepted }.sorted()

    fun get(name: String): PhoneSkillSaved = saved(existing(name))

    fun putDraft(document: PhoneSkillDocument, from: PhoneSkillOrigin, target: PhoneSkillBase? = null,
        source: String = "learned"): PhoneSkillPending {
        val safe = checked(document)
        if (source !in setOf("learned", "written")) invalidSkill("Invalid source.")
        if (target != null && target.name != safe.name) invalidSkill("An update must keep its name.")
        val pending = drafts()
        val prior = target?.draftId?.let { id ->
            pending.firstOrNull { it.id == id }?.takeIf { it.targetSnapshot().fingerprint == target.fingerprint }
                ?: changedSkill()
        }
        val base = if (target != null && prior == null) {
            val original = existing(safe.name)
            if (skillFingerprint(original.body!!) != target.fingerprint ||
                guestHash(safe.name) != target.fingerprint) changedSkill()
            original
        } else null
        if (prior == null && pending.any { it.document.name == safe.name }) changedSkill()
        if (target == null && occupied(safe.name)) changedSkill()
        // A replacement revokes the old review card, which can still be open in another UI.
        val next = PhoneSkillPending(UUID.randomUUID().toString(), safe, from, now(), source,
            prior?.original ?: base?.body, prior?.baseFingerprint ?: base?.body?.let(::skillFingerprint))
        writeDrafts((listOf(next) + pending.filter { it.id != prior?.id }).take(20))
        return next
    }

    fun accept(id: String, editedSections: Map<String, String>? = null): PhoneSkillSaved {
        val pending = drafts()
        val draft = pending.firstOrNull { it.id == id }
            ?: return list().skills.firstOrNull { it.status.lastAccepted == id } ?: changedSkill()
        val document = checked(if (editedSections == null) draft.document else draft.document.copy(sections = editedSections))
        val old = load(document.name)
        val original = old?.body
        val hash = guestHash(document.name)
        if (draft.baseFingerprint == null) {
            if (original != null || occupied(document.name)) changedSkill()
        } else if (original == null || skillFingerprint(original) != draft.baseFingerprint || hash != draft.baseFingerprint) {
            changedSkill()
        }
        val status = (if (original == null) PhoneSkillStatus() else old.status).copy(lastAccepted = id)
        val next = Record(document.name, document.render(status.state, draft.source, draft.from), status, now(),
            archive(old))
        val result = saved(commit(next, hash))
        writeDrafts(pending.filter { it.id != id })
        return result
    }

    fun discard(id: String) {
        val pending = drafts()
        writeDrafts(pending.filter { it.id != id })
    }

    fun save(name: String, display: String? = null, description: String? = null, whenToUse: String? = null,
        sections: Map<String, String>? = null): PhoneSkillSaved {
        val old = existing(name)
        val current = saved(old)
        val document = current.document
        val safe = checked(document.copy(display = display ?: document.display, description = description ?: document.description,
            whenToUse = whenToUse ?: document.whenToUse, sections = sections ?: document.sections))
        val body = safe.render(old.status.state, current.source, current.from)
        val hash = guestHash(name)
        if (hash != current.fingerprint) changedSkill()
        if (body == old.body) return current
        return saved(commit(old.copy(body = body, updated = now(), versions = archive(old)), hash))
    }

    fun setEnabled(name: String, on: Boolean): PhoneSkillSaved {
        val old = existing(name)
        return changeStatus(old, old.status.enable(on))
    }

    fun record(name: String, outcome: String, expectedDocument: PhoneSkillDocument? = null): PhoneSkillResult {
        val old = existing(name)
        if (expectedDocument != null && saved(old).document != expectedDocument) changedSkill()
        val status = old.status.record(outcome)
        val skill = changeStatus(old, status)
        val change = when {
            status.state == old.status.state -> null
            status.state == "suspended" -> "suspended"
            else -> "promoted"
        }
        return PhoneSkillResult(skill, change)
    }

    private fun changeStatus(old: Record, next: PhoneSkillStatus): PhoneSkillSaved {
        val current = saved(old)
        if (old.status == next) return current
        return saved(commit(old.copy(body = current.document.render(next.state, current.source, current.from),
            status = next, updated = now()), current.fingerprint, statusOnly = true))
    }

    fun restore(name: String): PhoneSkillSaved {
        val old = load(name) ?: changedSkill()
        val version = old.versions.firstOrNull() ?: invalidSkill("There is no previous version.")
        val (doc, source, from) = unpack(version.body)
        val body = checked(doc).render(old.status.state, source, from)
        val rest = old.copy(versions = old.versions.drop(1))
        val hash = guestHash(name)
        if (old.body == null && hash != null) changedSkill()
        return saved(commit(rest.copy(body = body, updated = now(), versions = archive(rest)), hash))
    }

    fun delete(name: String) {
        if (PhoneSkillDocument.legacyName.matches(name)) {
            val dir = skillDir(name)
            if (!Files.exists(dir, NOFOLLOW_LINKS)) return
            val md = dir.resolve("SKILL.md")
            if (Files.isRegularFile(md, NOFOLLOW_LINKS)) archiveLegacy(name, md)
            // These are the only files the former installers owned. Leave unrelated files alone.
            for (file in listOf("SKILL.md", "route.json", "revision.json")) Files.deleteIfExists(dir.resolve(file))
            removeEmpty(dir)
            return
        }
        val old = load(name) ?: changedSkill()
        if (old.body == null) return
        drafts() // Clear a completed accept receipt before deleting its published skill.
        commit(old.copy(body = null, updated = now(), versions = archive(old)), guestHash(name))
    }

    private fun archiveLegacy(name: String, path: Path) {
        // The old installer capped documents at 32 KiB. Bound an externally enlarged file too.
        val buffer = ByteArray(32 * 1024 + 1)
        var size = 0
        Files.newInputStream(path, NOFOLLOW_LINKS).use { input ->
            while (size < buffer.size) {
                val n = input.read(buffer, size, buffer.size - size)
                if (n < 0) break
                size += n
            }
        }
        val text = String(buffer, 0, minOf(size, buffer.size - 1), Charsets.UTF_8).replace("\r\n", "\n")
        val split = if (text.startsWith("---\n")) text.indexOf("\n---\n", 4) else -1
        val description = if (split == -1) "" else text.substring(4, split).lineSequence()
            .firstOrNull { it.startsWith("description:") }?.substringAfter(':')?.trim().orEmpty()
        val body = if (split == -1) text else text.substring(split + 5)
        val safe = buildString {
            append("---\nname: ").append(name).append("\ndescription: ").append(Json.write(cleanLegacy(description)))
            append("\ndisable-model-invocation: true\nuser-invocable: true\n---\n").append(cleanLegacy(body))
            if (size == buffer.size) append("\n[…]\n")
        }
        val dir = directory(directory(skills.resolve(".archive")).resolve(name))
        val prior = children(dir).mapNotNull { p ->
            p.fileName.toString().takeIf { it.endsWith(".md") }?.dropLast(3)?.toLongOrNull()
        }.sortedDescending()
        val latest = prior.firstOrNull()?.let { dir.resolve(it.toString() + ".md") }
        if (latest != null && Files.isRegularFile(latest, NOFOLLOW_LINKS) && fileHash(latest) == skillFingerprint(safe)) return
        val at = maxOf(now(), (prior.firstOrNull() ?: -1) + 1)
        atomic(dir.resolve(at.toString() + ".md"), safe)
        for (expired in prior.drop(4)) Files.delete(dir.resolve(expired.toString() + ".md"))
    }

    private fun checked(document: PhoneSkillDocument): PhoneSkillDocument {
        if (!PhoneSkillDocument.validName(document.name)) invalidSkill("Invalid skill name.")
        val safe = clean(document)
        if (safe.name != document.name) invalidSkill("Invalid skill name.")
        return safe
    }

    private fun unpack(body: String): Triple<PhoneSkillDocument, String, PhoneSkillOrigin?> {
        val metadata = PhoneSkillDocument.metadata(body)
        val source = metadata["source"]?.takeIf { it == "learned" || it == "written" } ?: invalidSkill("Invalid source.")
        return Triple(PhoneSkillDocument.parseMarkdown(body), source, metadata["learned-from"]?.let(PhoneSkillOrigin::parse))
    }

    private fun saved(record: Record): PhoneSkillSaved {
        val body = record.body ?: changedSkill()
        val (document, source, from) = unpack(body)
        return PhoneSkillSaved(document, source, from, record.status, record.updated,
            record.versions.map { it.at }, skillFingerprint(body))
    }

    private fun existing(name: String) = load(name)?.takeIf { it.body != null } ?: changedSkill()

    private fun archive(old: Record?): List<Version> {
        if (old?.body == null) return old?.versions.orEmpty()
        val at = maxOf(now(), (old.versions.firstOrNull()?.at ?: -1) + 1)
        return (listOf(Version(at, old.body)) + old.versions).take(5)
    }

    private fun occupied(name: String) = load(name)?.body != null || Files.exists(skillDir(name), NOFOLLOW_LINKS)

    private fun drafts(): List<PhoneSkillPending> {
        val path = pendingFile
        if (!Files.exists(path, NOFOLLOW_LINKS)) return emptyList()
        val rows = Json.parseStrict(read(path)) as List<*>
        val oldest = now() - 30L * 24 * 60 * 60 * 1000
        val current = rows.mapNotNull { value ->
            val row = value as Map<*, *>
            val at = row["createdAt"] as Long
            if (at <= oldest) return@mapNotNull null
            val (document, source, from) = unpack(row["body"] as String)
            val id = row["id"] as String
            if (load(document.name)?.status?.lastAccepted == id) return@mapNotNull null
            PhoneSkillPending(id, document, from ?: invalidSkill("Missing task origin."), at, source,
                row["original"] as String?, row["baseFingerprint"] as String?)
        }.take(20)
        if (rows.size != current.size) writeDrafts(current)
        return current
    }

    private fun writeDrafts(rows: List<PhoneSkillPending>) = atomic(pendingFile, Json.write(rows.map { it.disk() }))

    private fun load(name: String): Record? {
        if (!PhoneSkillDocument.validName(name)) invalidSkill("Invalid skill name.")
        val pending = records.resolve(name + ".pending")
        if (Files.exists(pending, NOFOLLOW_LINKS)) {
            val staged = decode(name, pending)
            if (publish(staged)) return staged.copy(previous = null, statusOnly = false)
        }
        val path = records.resolve(name + ".json")
        return if (Files.exists(path, NOFOLLOW_LINKS)) decode(name, path) else null
    }

    private fun decode(name: String, path: Path): Record {
        val row = Json.parseStrict(read(path)) as Map<*, *>
        val s = row["status"] as Map<*, *>
        val status = PhoneSkillStatus(s["state"] as String, s["uses"] as Long,
            (s["recent"] as List<*>).map { it as String }, s["proven"] as Boolean,
            (s["scored"] as List<*>).map { it as String }, s["lastAccepted"] as String?,
            s["suspensionReason"] as String?)
        val versions = (row["versions"] as List<*>).map {
            val item = it as Map<*, *>
            Version(item["at"] as Long, item["body"] as String)
        }
        return Record(name, row["body"] as String?, status, row["updated"] as Long, versions,
            row["previous"] as String?, row["statusOnly"] == true)
    }

    private fun commit(next: Record, previous: String?, statusOnly: Boolean = false): Record {
        val staged = next.copy(previous = previous, statusOnly = statusOnly)
        atomic(records.resolve(next.name + ".pending"), Json.write(staged.disk()))
        if (!publish(staged)) changedSkill()
        return next
    }

    private fun publish(record: Record): Boolean {
        val pending = records.resolve(record.name + ".pending")
        if (record.statusOnly) {
            // State is native-owned. An independently edited or unlinked guest document cannot
            // veto a suspension and must not be replaced by our mirror. Never follow a guest link.
            val dir = skills.resolve(record.name)
            if (Files.isDirectory(dir, NOFOLLOW_LINKS)) {
                val md = dir.resolve("SKILL.md")
                atomic(dir.resolve(".state.json"), stateMirror(record))
                if (Files.isRegularFile(md, NOFOLLOW_LINKS) && fileHash(md) == record.previous &&
                    skillFingerprint(record.body!!) != record.previous) atomic(md, record.body)
            }
            finish(record, pending)
            return true
        }
        val dir = skillDir(record.name)
        val actual = guestHash(record.name)
        val desired = record.body?.let(::skillFingerprint)
        if (actual != desired && actual != record.previous) {
            // The previous private record is intact. Keep the foreign edit and retire this proposal.
            Files.delete(pending)
            return false
        }
        val archive = skills.resolve(".archive")
        if (record.versions.isNotEmpty() || Files.exists(archive.resolve(record.name), NOFOLLOW_LINKS)) {
            val versionsDir = directory(directory(archive).resolve(record.name))
            for (version in record.versions) {
                val path = versionsDir.resolve(version.at.toString() + ".md")
                if (!Files.isRegularFile(path, NOFOLLOW_LINKS) || fileHash(path) != skillFingerprint(version.body))
                    atomic(path, version.body)
            }
            val retained = record.versions.map { it.at }
            for (path in children(versionsDir)) {
                val file = path.fileName.toString()
                if (file.endsWith(".md") && file.dropLast(3).toLongOrNull()?.let { it !in retained } == true)
                    Files.delete(path)
            }
        }
        if (record.body == null) {
            if (Files.exists(dir, NOFOLLOW_LINKS)) {
                Files.deleteIfExists(dir.resolve("SKILL.md"))
                Files.deleteIfExists(dir.resolve(".state.json"))
                removeEmpty(dir)
            }
        } else {
            directory(dir)
            atomic(dir.resolve(".state.json"), stateMirror(record))
            if (actual != desired) atomic(dir.resolve("SKILL.md"), record.body)
        }
        finish(record, pending)
        return true
    }

    private fun stateMirror(record: Record) = Json.write(record.status.toMap().filterKeys { it != "lastAccepted" })

    private fun finish(record: Record, pending: Path) {
        atomic(records.resolve(record.name + ".json"), Json.write(record.copy(previous = null, statusOnly = false).disk()))
        Files.delete(pending)
    }

    private fun skillDir(name: String): Path {
        val path = skills.resolve(name)
        if (Files.exists(path, NOFOLLOW_LINKS) && !Files.isDirectory(path, NOFOLLOW_LINKS))
            invalidSkill("Invalid skill directory.")
        return path
    }

    private fun guestHash(name: String): String? {
        val path = skillDir(name).resolve("SKILL.md")
        if (!Files.exists(path, NOFOLLOW_LINKS)) return null
        if (!Files.isRegularFile(path, NOFOLLOW_LINKS)) invalidSkill("Invalid skill file.")
        return fileHash(path)
    }

    private fun fileHash(path: Path): String {
        val digest = MessageDigest.getInstance("SHA-256")
        Files.newInputStream(path, NOFOLLOW_LINKS).use { input ->
            val buffer = ByteArray(8192)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                digest.update(buffer, 0, n)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun children(path: Path): List<Path> = Files.newDirectoryStream(path).use { it.toList() }

    private fun directory(path: Path): Path {
        if (!Files.exists(path, NOFOLLOW_LINKS)) Files.createDirectory(path)
        if (!Files.isDirectory(path, NOFOLLOW_LINKS)) invalidSkill("Invalid skill directory.")
        return path
    }

    private fun removeEmpty(path: Path) {
        try { Files.delete(path) } catch (_: DirectoryNotEmptyException) { /* Another file belongs to its writer. */ }
    }

    private fun read(path: Path): String = Files.newInputStream(path, NOFOLLOW_LINKS).bufferedReader().use { it.readText() }

    private fun atomic(path: Path, value: String) {
        val temp = Files.createTempFile(path.parent, ".publish-", ".tmp")
        try {
            FileChannel.open(temp, WRITE, NOFOLLOW_LINKS).use { channel ->
                val bytes = ByteBuffer.wrap(value.toByteArray(Charsets.UTF_8))
                while (bytes.hasRemaining()) channel.write(bytes)
                channel.force(true)
            }
            Files.move(temp, path, ATOMIC_MOVE, REPLACE_EXISTING)
        } finally {
            Files.deleteIfExists(temp)
        }
    }
}
