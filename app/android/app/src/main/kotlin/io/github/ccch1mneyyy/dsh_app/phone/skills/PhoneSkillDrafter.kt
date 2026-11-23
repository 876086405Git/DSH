package io.github.ccch1mneyyy.dsh_app.phone.skills

import io.github.ccch1mneyyy.dsh_app.phone.Json
import io.github.ccch1mneyyy.dsh_app.phone.PhoneToolCatalog
import java.util.Locale

internal object PhoneSkillDrafter {
    const val TEMPLATE_ASSET = "phone/skill_draft.md"
    data class Target(val document: PhoneSkillDocument, val base: PhoneSkillBase)
    data class Proposal(val document: PhoneSkillDocument, val target: PhoneSkillBase?)

    /** The prompt deliberately has no task text, final message, snapshots, or stable skill IDs. */
    fun prepare(template: String, english: Boolean, trace: PhoneTaskTrace.Snapshot, targets: List<Target>): Request? {
        if (!trace.canLearn) return null
        val apps = trace.steps.filter { it.receipt == PhoneTaskTrace.Receipt.RETURNED_OK }
            .mapNotNull { it.packageName }.distinct()
        val references = targets.mapIndexed { index, target -> "S${index + 1}" to target }.toMap()
        val procedures = references.map { (reference, target) ->
            val description = (target.document.display + " " + target.document.description).lowercase(Locale.ROOT)
            mapOf("reference" to reference, "apps" to target.document.apps,
                "public_topics" to topics.filterValues { patterns -> patterns.any { it.containsMatchIn(description) } }.keys.toList())
        }
        val accepted = trace.steps.filter { it.receipt == PhoneTaskTrace.Receipt.RETURNED_OK }
        val data = mapOf(
            "language" to if (english) "en" else "zh",
            "inferred_goal" to mapOf("apps" to apps, "last_public_action" to
                (accepted.lastOrNull { it.anchor != null }?.anchor?.name ?: accepted.last().action.name)),
            "run_result" to "completed",
            "available_tools" to PhoneToolCatalog.names.map { "mcp__phone__" + it },
            "actions" to trace.steps.map { step ->
                buildMap<String, Any?> {
                    put("action", step.action.name)
                    step.packageName?.let { put("app", it) }
                    if (step.role != PhoneTaskTrace.Role.UNKNOWN) put("role", step.role.name)
                    step.anchor?.let { put("public_control", it.name) }
                    if (step.action in setOf(PhoneTaskTrace.Action.TYPE, PhoneTaskTrace.Action.TYPE_SUBMIT))
                        put("input", if (english) "<input>" else "<输入内容>")
                    put("result", when (step.receipt) {
                        PhoneTaskTrace.Receipt.RETURNED_OK -> when (step.screenChanged) {
                            true -> "screen_changed"
                            false -> "screen_unchanged"
                            null -> "accepted_unverified"
                        }
                        PhoneTaskTrace.Receipt.STALE_REJECTED -> "stale_not_dispatched"
                        PhoneTaskTrace.Receipt.RETURNED_ERROR -> "error"
                        PhoneTaskTrace.Receipt.CALLED, PhoneTaskTrace.Receipt.UNCERTAIN -> "unknown"
                    })
                }
            },
            "existing_procedures" to procedures,
        )
        return Request(template + "\n\n" + Json.write(data), english, apps, references)
    }

    class Request internal constructor(val prompt: String, private val english: Boolean, private val apps: List<String>,
                                       private val references: Map<String, Target>) {
        fun parse(response: String): Proposal? {
            val raw = response.trim()
            if (raw == "SKIP") return null
            val meta = PhoneSkillDocument.metadata(raw)
            if (meta.keys.any { it !in modelFields } || meta["source"]?.let { it != "learned" } == true)
                invalidSkill("Unexpected model metadata.")
            val target = meta["updates"]?.let { references[it] ?: invalidSkill("Unknown update target.") }
            val parsed = PhoneSkillDocument.parseMarkdown(raw)
            if (parsed.english != english) invalidSkill("Unexpected section language.")
            if (target != null && parsed.name != "phone-update") invalidSkill("Expected an update name.")
            if (target == null && references.values.any { it.document.name == parsed.name }) invalidSkill("Name already exists.")
            val allowedApps = apps + target?.document?.apps.orEmpty()
            if (parsed.apps.any { it !in allowedApps }) invalidSkill("Unobserved app.")
            val document = PhoneSkillValidation.clean(parsed.copy(name = target?.base?.name ?: parsed.name))
            return Proposal(document, target?.base)
        }
    }

    private val modelFields = setOf("name", "display", "description", "when-to-use", "apps", "source", "updates")

    // Only constants from this vocabulary may represent editable catalog descriptions in a draft request.
    private val topics = mapOf(
        "search" to listOf("搜索", "查找", "\\bsearch\\b", "\\bfind\\b"),
        "send" to listOf("发送", "发语音", "\\bsend\\b"),
        "message" to listOf("消息", "聊天", "\\bmessages?\\b", "\\bchat\\b"),
        "voice" to listOf("语音", "\\bvoice\\b"),
        "save" to listOf("保存", "\\bsave\\b"),
        "open" to listOf("打开", "\\bopen\\b"),
        "select" to listOf("选择", "\\bselect\\b"),
        "delete" to listOf("删除", "\\bdelete\\b"),
        "submit" to listOf("提交", "\\bsubmit\\b"),
        "settings" to listOf("设置", "\\bsettings\\b"),
        "contact" to listOf("联系人", "\\bcontacts?\\b"),
        "file" to listOf("文件", "\\bfiles?\\b"),
    ).mapValues { (_, patterns) -> patterns.map(::Regex) }
}
