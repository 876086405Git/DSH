package io.github.ccch1mneyyy.dsh_app.phone

import android.os.Handler
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executor
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * Local companion transport only. Admission, execution, deadlines, native reply
 * commits and cleanup all remain in the existing PhoneControl/Core/SafetyGate.
 */
internal class CompanionPhoneBridge(
    private val control: PhoneControl,
    private val main: Handler,
    private val calls: Executor,
    private val cleanup: Executor,
    private val attached: () -> Boolean,
) {
    private data class Key(val session: String, val run: String)
    private data class Step(val reply: String, val publish: () -> Unit)
    private class Run(val key: Key, val requestId: String, val epoch: Long) {
        @Volatile var retired = false
        var approved = false
        var pending = 0
        var cleanupDone = false
        var cleanupFailed = false
        val callIds = HashSet<String>()
        val endReplies = ArrayList<MethodChannel.Result>()
    }
    private val runs = LinkedHashMap<Key, Run>()
    private val ended = HashSet<Key>()
    private val owner = Any()

    private fun current(run: Run) = attached() && !run.retired && run.epoch == control.companionPhoneEpoch()

    // The native diagnostics tool explicitly requires an engine caller. This
    // text-only model cannot consume the image required by coordinate actions.
    private val tools = PhoneToolCatalog.tools.filter {
        it.name != PhoneToolCatalog.DIAGNOSTICS && it.name != PhoneToolCatalog.TAP_XY
    }.map {
        if (it.name == PhoneToolCatalog.SCREEN) PhoneToolCatalog.Tool(it.name,
            "读当前屏幕的文字和元素。编号只在本屏有效，background:true 读后台屏。无法核对目标就 handoff。", // l10n:keep agent tool catalog
            it.properties - "image", it.required)
        else it
    }
    private val names = tools.map { it.name }.toSet()

    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "companionPhoneTools" -> result.success(tools.map { it.toJson() })
            "companionPhoneBegin" -> begin(call, result)
            "companionPhoneCall" -> invoke(call, result)
            "companionPhoneEnd" -> end(call, result)
            else -> return false
        }
        return true
    }

    private fun key(args: Map<*, *>?): Key? {
        if (args == null) return null
        val session = PhoneCaller.identifier(args["sessionId"]) ?: return null
        val run = PhoneCaller.identifier(args["runId"]) ?: return null
        if (!session.startsWith("companion:") || session.length > 200) return null
        return Key(session, run)
    }

    private fun begin(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val key = key(args)
        val source = PhoneCaller.identifier(args?.get("sourceId"))
        val revision = (args?.get("sourceRev") as? Number)?.toLong()
        val raw = args?.get("sourceText") as? String
        val first = args?.get("firstTool") as? String
        if (args == null || key == null || source == null || revision == null || revision < 1 ||
            raw.isNullOrBlank() || first !in names ||
            args.keys != setOf("sessionId", "runId", "sourceId", "sourceRev", "sourceText", "firstTool")) {
            result.success(PhonePrompts.unavailable("invalid")); return
        }
        if (!attached() || key in ended || runs.containsKey(key)) {
            result.success(PhonePrompts.unavailable("stale")); return
        }
        runs.values.filter { !it.retired && it.epoch != control.companionPhoneEpoch() }.toList()
            .forEach { retire(it, true) }
        if (runs.values.any { !it.retired }) {
            result.success(PhonePrompts.unavailable("busy")); return
        }
        val run = Run(key, "companion-${java.util.UUID.randomUUID()}", control.companionPhoneEpoch())
        runs[key] = run
        val firstDescription = tools.first { it.name == first }.description.substringBefore('。').take(160)
        // l10n:keep companion phone approval uses the actual submitted user text
        val text = "按你刚才的要求操作手机吗？\n“${raw.take(3000)}”\n先做：$firstDescription。" +
            if (raw.length > 3000) "\n（上方显示原话开头；每项操作仍按原生安全规则确认。）" else ""
        control.prompts.present(
            EnginePhonePrompt(run.requestId, null, key.session, "手机伙伴", PromptKind.APPROVAL, text),
            owner, { current(run) },
        ) { answer ->
            if (current(run) && runs[key] === run) {
                run.approved = answer["decision"] == "allowed-once"
                result.success(answer)
            } else if (attached()) {
                result.success(PhonePrompts.unavailable("stopped"))
            }
        }
    }

    private fun invoke(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val key = key(args)
        val callId = PhoneCaller.identifier(args?.get("callId"))
        val name = args?.get("name") as? String
        val input = args?.get("arguments") as? Map<*, *>
        val run = key?.let(runs::get)
        if (args == null || key == null || callId == null || name !in names || input == null ||
            args.keys != setOf("sessionId", "runId", "callId", "name", "arguments")) {
            result.success(failure(callId, "手机工具参数不完整，没有执行。")); return // l10n:keep agent error
        }
        if (run == null || !current(run) || !run.approved || key in ended) {
            result.success(failure(callId, "本轮没有当前授权，没有执行手机操作。")); return // l10n:keep agent error
        }
        if (!run.callIds.add(callId)) {
            result.success(failure(callId, "此调用已经提交过，不能自动重复操作。")); return // l10n:keep agent error
        }
        val step = AtomicReference<Step?>(null)
        val work = try {
            // Match the JSON numeric/map types used by the original MCP parser.
            @Suppress("UNCHECKED_CAST")
            val normalized = Json.parse(Json.write(input)) as Map<String, Any?>
            val arguments = if (name == PhoneToolCatalog.SCREEN) normalized + ("image" to false) else normalized
            control.companionPhoneCall(PhoneCaller(key.session, key.run, callId, 1), name!!, arguments, run.epoch,
                { current(run) }, { reply, publish -> step.set(Step(reply, publish)) })
        } catch (_: Exception) {
            result.success(failure(callId, "手机暂时无法接纳这一条，没有重新排队。")); return // l10n:keep agent error
        }
        run.pending++
        val answered = AtomicBoolean(false)
        fun deliver(reply: String) {
            if (answered.compareAndSet(false, true)) main.post {
                // Publish only the actual winning reply. A deadline can win
                // before an abandoned body returns a different success result.
                val ready = step.getAndSet(null)
                if (ready != null && current(run) && ready.reply == reply) {
                    try { ready.publish() } catch (_: Exception) { /* Presentation cannot change the tool receipt. */ }
                }
                if (attached()) result.success(reply)
            }
        }
        work.schedule(deadlines, ::deliver)
        calls.execute {
            try {
                work.run()?.let(::deliver)
            } catch (_: Throwable) {
                deliver(failure(callId, "手机操作结果未知，不能自动重试。")) // l10n:keep agent error
            } finally {
                main.post { run.pending--; finish(run) }
            }
        }
    }

    private fun end(call: MethodCall, result: MethodChannel.Result) {
        val args = call.arguments as? Map<*, *>
        val key = key(args)
        if (args == null || key == null || args["stopped"] !is Boolean ||
            args.keys != setOf("sessionId", "runId", "stopped")) {
            result.error("invalid_phone_run", "An exact companion run is required", null); return
        }
        val run = runs.getOrPut(key) { Run(key, "", control.companionPhoneEpoch()) }
        run.endReplies += result
        retire(run, args["stopped"] == true)
    }

    private fun retire(run: Run, stopped: Boolean) {
        if (run.retired) { finish(run); return }
        run.retired = true
        ended += run.key
        if (run.requestId.isNotEmpty()) control.prompts.cancel(run.requestId)
        // Admission is sealed on the MethodChannel thread before any queued
        // call can run. A real stop also invokes the original synchronous stop.
        val settle = try {
            control.endCompanionPhoneRun(run.key.session, run.key.run, stopped || run.pending > 0)
        } catch (_: Exception) {
            run.cleanupFailed = true
            run.cleanupDone = true
            finish(run)
            return
        }
        cleanup.execute {
            var failed = false
            try { settle() } catch (_: Throwable) { failed = true }
            finally { main.post { run.cleanupFailed = failed; run.cleanupDone = true; finish(run) } }
        }
    }

    private fun finish(run: Run) {
        if (!run.retired || !run.cleanupDone || run.pending != 0) return
        runs.remove(run.key, run)
        val replies = run.endReplies.toList()
        run.endReplies.clear()
        if (attached()) replies.forEach {
            if (run.cleanupFailed) it.error("phone_end_unknown", "Native cleanup is not confirmed", null)
            else it.success(null)
        }
    }

    fun detach() {
        runs.values.toList().forEach { retire(it, true) }
        control.prompts.detachOwner(owner)
    }

    private fun failure(callId: String?, words: String) =
        McpServer.result(callId, McpServer.toolResult(ToolOutput(words, isError = true)))

    companion object {
        private val deadlines = ScheduledThreadPoolExecutor(1) { r ->
            Thread(r, "dsh-companion-phone-deadline").apply { isDaemon = true }
        }.apply { removeOnCancelPolicy = true }
    }
}
