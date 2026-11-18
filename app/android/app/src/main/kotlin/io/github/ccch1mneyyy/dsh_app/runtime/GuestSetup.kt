// SPDX-FileCopyrightText: 2026 Fei2411 and the DS Bot contributors
// SPDX-License-Identifier: Apache-2.0
// See THIRD_PARTY_NOTICES.md.
// Modified: the `show_view` description and prompt rule (`ds-bot/src/host/tools.js`, `prompt.js`)
// rewritten as Chinese instructions for a ```dsh-ui fenced block in a phone chat.
package io.github.ccch1mneyyy.dsh_app.runtime

import android.content.Context
import android.net.ConnectivityManager
import android.system.ErrnoException
import android.system.Os
import io.github.ccch1mneyyy.dsh_app.files.GuestFiles
import io.github.ccch1mneyyy.dsh_app.phone.PhoneGuest
import java.io.File
import java.io.IOException
import java.net.Inet4Address
import java.net.InetAddress
import java.nio.file.Files
import java.nio.file.LinkOption

/** Small files inside the rootfs that must reflect the device before each start. */
object GuestSetup {
    private val FALLBACK_DNS = listOf("223.5.5.5", "119.29.29.29", "8.8.8.8")

    private const val AGENTS_MARKER = "<!-- dsh-app:managed"

    // l10n:keep agent prompt
    private val AGENTS_MD = ("""
        |<!-- dsh-app:managed — 删除这一行后，DSH App 不再覆盖本文件 -->
        |# 运行环境（DSH 手机版）
        |
        |- 你运行在 Android 手机上的 Ubuntu 24.04 环境里（proot，免 Root）。这里没有可用的沙箱后端（bubblewrap / Landlock 都不可用），`workspace-write` 沙箱模式一定会被拒绝。
""" +
        // l10n:keep agent prompt
        """        |- 需要执行 bash 命令时，直接用 `sandbox_permissions: "danger-full-access"` 申请运行，并用一句话写明理由；不要先试沙箱模式。
        |- 默认工作目录是 `/root/workspace`。{STORAGE_LINE}
        |- 已预装 node / npm / pnpm、python3 / pip、git；npm 和 pnpm 默认用国内镜像 registry.npmmirror.com。缺别的工具可以 `apt-get update && apt-get install -y <包名>`（需要联网）。
        |- 手机屏幕小：回复尽量简洁，代码块不要太宽；用用户使用的语言回答。
        |
        |## 界面与技能
        |
        |- 这个 App 的对话界面是 Flutter 原生界面，不是 Harness Web Client。改 App 自己的样子用 dsh-go-ui（ui.json）；给 App 加胶囊、菜单项、状态条、原生面板、工具卡这类功能用 dsh-go-plugin；只有用户明确要做 Cordis 插件、或要改 Harness 网页版 / 桌面端时，才用官方 cordis-plugin-development 等技能。
        |- 没点名界面载体时，手机上的默认目标是 dsh-go 原生界面；先确定载体再选技能，不要按加载顺序决定。
        |- dsh-go 原生插件不是 Cordis bundle：目录在 `${'$'}DSH_HOME/dsh-go/plugins/`，安装用 `dsh plugin --profile web add`；官方技能里的「工作区建包 + plugin_manager install_bundle」只用于 Cordis 插件，两套不要混用。
        |- 用户报障、排查问题、写 bug 反馈时加载 `dsh-go-support` 技能：它教你怎么读本机诊断、按症状定位、生成脱敏的 issue 草稿。
        |""").trimMargin()

    private val AGENTS_MD_EN = """
        |<!-- dsh-app:managed — Remove this line to prevent DSH App from overwriting this file -->
        |# Runtime environment (DSH mobile app)
        |
        |- You are running in an Ubuntu 24.04 environment (proot, no root required) on an Android phone. There is no usable sandbox backend here (neither bubblewrap nor Landlock is available), and the `workspace-write` sandbox mode will always be rejected.
        |- When you need to run a bash command, request execution directly with `sandbox_permissions: "danger-full-access"` and give a one-sentence reason; do not try sandbox mode first.
        |- The default working directory is `/root/workspace`. {STORAGE_LINE}
        |- node / npm / pnpm, python3 / pip, and git are preinstalled; npm and pnpm use the Chinese mirror registry.npmmirror.com by default. If other tools are missing, you can use `apt-get update && apt-get install -y <package-name>` (requires network access).
        |- Phone screens are small: keep replies as concise as possible and avoid overly wide code blocks; reply in the language the user uses.
        |
        |## Interface and skills
        |
        |- This App's chat interface is a native Flutter interface, not Harness Web Client. Use dsh-go-ui (ui.json) to change the App's appearance; use dsh-go-plugin to add features such as capsules, menu items, status bars, native panels, and tool cards. Use official skills such as cordis-plugin-development only when the user explicitly asks to create a Cordis plugin or change the Harness web or desktop interface.
        |- If the user does not specify an interface, the default target on the phone is the dsh-go native interface. Identify the interface first, then choose a skill; do not choose based on loading order.
        |- dsh-go native plugins are not Cordis bundles: their directory is `${'$'}DSH_HOME/dsh-go/plugins/`, and they are installed with `dsh plugin --profile web add`. The official skills' "create a package in the workspace + plugin_manager install_bundle" workflow is only for Cordis plugins; do not mix the two.
        |- When the user reports an issue, when troubleshooting, or when writing a bug report, load the `dsh-go-support` skill: it explains how to read local diagnostics, investigate by symptom, and generate a redacted issue draft.
        |""".trimMargin()

    /**
     * Appended while 「可视化回复」 is on (default): how to answer with a ```dsh-ui view. The
     * component list and the rules are written for a fenced block in a phone chat.
     */
    // l10n:keep agent prompt
    private val DSH_UI_SECTION = ("""
        |
        |## 可视化回复（dsh-ui）
        |
        |- 这个 App 能把带 ```dsh-ui 标记的代码块画成原生的图表和卡片。只在比文字更清楚时用：比较数值或看趋势用 chart，几个关键数字用 metric，方案对比用 compare，步骤和进度用 steps，需要用户点选时用 options 或 confirm。闲聊、单个数字、普通列表都不用。
        |- 先用一两句话给出结论，再放视图。同一份数据不要用文字、表格、图表各写一遍。一条回复最多两个视图。
        |- 必须写成围栏代码块：第一行单独写 ```dsh-ui，下一行开始是 JSON，最后一行单独写 ```。直接把 JSON 裸着写进正文是纯文本，画不出来。
        |- 围栏里只放一个 JSON 对象，不写注释和尾逗号，不超过 4 KB。数据必须真实；示例或估算的数字在 caption 里说明。
        |- 组件：stack / row {children}；text {text}；metric {label, value, tone?: good|warn|bad, caption?}；chart {kind: bar|hbar|line|donut, categories, series: [{name?, values}], unit?, caption?}（values 与 categories 一一对应，最多 6 组、每组 60 个点；donut 只放一组）；compare {items: [{title, badge?, rows: [[名称, 值]]}]}（2–4 项）；steps {items: [{label, status: done|current|todo|failed, detail?}]}；callout {text, tone?: info|good|warn|bad}；options {id, options: [{label, description?}], multi?, freetext?}（最多 8 个）；confirm {id, confirmLabel?, cancelLabel?}。根节点可以带 title。
        |- options 想允许「选项以外」的回答时加 `freetext: true`（也可以写成一句提示词，如 `freetext: "自己写一个"`）：选项下面会出现输入框，用户填的内容会以「其他：…」跟选择一起回传。
""" +
        // l10n:keep agent prompt
        """        |- 例：
        |```dsh-ui
        |{"type":"stack","title":"近 6 个月支出","children":[{"type":"metric","label":"月均","value":"¥4,180"},{"type":"chart","kind":"bar","categories":["5月","6月"],"series":[{"values":[3800,4100]}],"unit":"元"}]}
        |```
""" +
        // l10n:keep agent prompt
        """        |- 含 options 或 confirm 的视图放在回复最后，然后结束这一轮；用户的选择会以一条 "[dsh-ui reply]" 开头的消息发回来（如「选择：方案 A」「确认：开始」；自己填的另起一行「其他：…」）。只问一个简单问题时用 ask_user_question。
        |- 不要用视图收集密码、密钥或验证码。
        |""").trimMargin()

    private val DSH_UI_SECTION_EN = """
        |
        |## Visual replies (dsh-ui)
        |
        |- This App can render code blocks marked with ```dsh-ui as native charts and cards. Use them only when they are clearer than text: chart for comparing values or viewing trends, metric for a few key numbers, compare for comparing alternatives, steps for steps and progress, and options or confirm when the user needs to make a selection. Do not use them for casual conversation, a single number, or an ordinary list.
        |- Start with the conclusion in one or two sentences, then include the view. Do not repeat the same data in prose, a table, and a chart. Use at most two views in one reply.
        |- Use a fenced code block: put ```dsh-ui alone on the first line, start the JSON on the next line, and put ``` alone on the final line. JSON written directly in the reply is plain text and will not render.
        |- Put only one JSON object inside the fence, with no comments or trailing commas, and keep it within 4 KB. The data must be real; identify example or estimated numbers in caption.
        |- Components: stack / row {children}; text {text}; metric {label, value, tone?: good|warn|bad, caption?}; chart {kind: bar|hbar|line|donut, categories, series: [{name?, values}], unit?, caption?} (values correspond one-to-one with categories; at most 6 series with 60 points each; donut has only one series); compare {items: [{title, badge?, rows: [[name, value]]}]} (2–4 items); steps {items: [{label, status: done|current|todo|failed, detail?}]}; callout {text, tone?: info|good|warn|bad}; options {id, options: [{label, description?}], multi?, freetext?} (at most 8 options); confirm {id, confirmLabel?, cancelLabel?}. The root node can have title.
        |- To let users answer outside the listed options, add `freetext: true` to options (or use a prompt string, such as `freetext: "Write your own"`): an input field appears below the options, and the user's text is returned together with the selection as "Other: …".
        |- Example:
        |```dsh-ui
        |{"type":"stack","title":"Spending over the last 6 months","children":[{"type":"metric","label":"Monthly average","value":"¥4,180"},{"type":"chart","kind":"bar","categories":["May","June"],"series":[{"values":[3800,4100]}],"unit":"yuan"}]}
        |```
        |- Place a view containing options or confirm at the end of the reply, then end this turn. The user's selection will come back as a message starting with "[dsh-ui reply]" (for example, "Select: Option A" or "Confirm: Start"; free text appears on a new line as "Other: …"). Use ask_user_question when asking a single simple question.
        |- Do not use views to collect passwords, secret keys, or verification codes.
        |""".trimMargin()

    // l10n:keep agent prompt
    private val DIAGNOSTICS_SECTION = """
        |
        |## 本机诊断
        |
        |- 用户报障（卡顿、发热、连不上、更新失败、闪退、插件不生效、手机操控失败）时，读取可用诊断：用户刚主动发布时优先读同目录的 `diagnostics-manual.md`，否则先读自动快照 `{PATH}`。核对报告时间、版本和设备，再分析引擎状态、连接方式、性能与有限日志；有一份可用就不要因另一份缺失反复要求刷新，读取前不用另问。
        |- 用户点过「让 AI 看诊断」后，同目录的 `diagnostics-manual.md` 保留最近一次手动报告（可能含本次同意采集的输入法证据）；存在时也读它并核对采集时间。后续自动快照不会覆盖它；下一次手动发布才替换，清除 App 内存证据不会撤回已发布文件。
        |- 新版本提供 `mcp__phone__diagnostics` 时，报障后先自行刷新并按 summary/evidence/appErrors/voice/engine/failure 段读取，无需先读屏、开启手机操控或授予高权限。核对采集时间、refreshed 和错误码；不支持时读已有快照。工具不采系统输入法证据，不替用户外发报告。
        |- 需要更多细节时，再让用户在 设置 → 诊断 里导出诊断包（zip）；它仍受日志数量和大小限制。数据不足就直说，不要凭猜测下结论。
        |- 报告会尝试脱敏，但不能保证没有遗漏。外发前人工检查凭据、路径和设备信息，不把完整报告或秘密原样贴到聊天或 issue 里。
        |- 完整的排查流程（症状清单、issue 模板、隐私红线）在 `dsh-go-support` 技能里；用户报障时加载它再动手。
        |""".trimMargin()

    private val DIAGNOSTICS_SECTION_EN = """
        |
        |## Local diagnostics
        |
        |- When the user reports a problem (slowdowns, overheating, connection failures, failed updates, crashes, plugins not working, or phone-control failures), read the available diagnostics: if the user has just chosen to publish a report, prefer `diagnostics-manual.md` in the same directory; otherwise, read the automatic snapshot at `{PATH}` first. Check the report time, version, and device, then analyze engine status, connection mode, performance, and the limited logs. If one report is available, do not repeatedly request a refresh just because the other is missing; there is no need to ask separately before reading.
        |- After the user taps "Let the AI read diagnostics", `diagnostics-manual.md` in the same directory keeps the most recent manual report (which may include input-method evidence the user consented to collect this time). If it exists, also read it and check its collection time. Later automatic snapshots do not overwrite it; only the next manual publication replaces it. Clearing the App's in-memory evidence does not retract files that have already been published.
        |- When a newer version provides `mcp__phone__diagnostics`, refresh the diagnostics yourself after a problem is reported, then read the summary/evidence/appErrors/voice/engine/failure sections, without first reading the screen, enabling phone control, or obtaining elevated permissions. Check the collection time, refreshed, and error codes; if the tool is not supported, read the existing snapshots. The tool does not collect system input-method evidence or send reports externally on the user's behalf.
        |- If more detail is needed, ask the user to export a diagnostic bundle (zip) from Settings → Diagnostics; it is still subject to limits on log count and size. Say explicitly when the data is insufficient; do not draw conclusions from guesses.
        |- Reports attempt to redact sensitive data, but omissions are still possible. Before sharing externally, have a person check credentials, paths, and device information; do not paste complete reports or secrets verbatim into chat or issues.
        |- The complete troubleshooting workflow (symptom checklist, issue template, and privacy boundaries) is in the `dsh-go-support` skill; load it before starting when the user reports a problem.
        |""".trimMargin()

    // l10n:keep guest path
    private const val STORAGE_GRANTED_EN = "The user has authorized access to phone storage: internal phone storage is mounted at `/sdcard` (`/root/手机存储` is a shortcut to it; photos are in `/sdcard/DCIM`, and downloads are in `/sdcard/Download`). Before modifying or deleting user files, explain the change and obtain confirmation; put files produced for the user in `/sdcard/Download/DSH-Go/`."
    private const val STORAGE_UNAVAILABLE_EN = "User files such as phone photos and downloads are not in this environment and cannot be seen here; if access is needed, ask the user to turn on \"Access phone files\" in the App's settings."
    private const val DIRECT_ENVIRONMENT_FROM_EN = "Ubuntu 24.04 environment (proot, no root required)"
    private const val DIRECT_ENVIRONMENT_TO_EN = "Ubuntu 24.04 runtime environment (the engine starts directly; bash/git/python/apt tools still run through proot)"
    private const val DIRECT_PATH_NOTE_EN = "\n- File tools, session directories, @ references, AGENTS, and skills use the same full absolute path; that path is also visible under the same name in the shell. Legacy `/root` paths remain available to file tools. Shell output is not rewritten; do not remove path prefixes.\n"

    /** Where the engine's agent finds that snapshot, inside the guest. */
    private const val DIAGNOSTICS_FILE = "root/.dsh/dsh-app/diagnostics.md"

    /** Atomically replaces one fixed report and returns its actual host file. */
    fun writeDiagnostics(rootfs: File, markdown: String, safe: Boolean = false, manual: Boolean = false): File {
        val path = if (safe) "${SafeMode.HOME.removePrefix("/")}/dsh-app/diagnostics.md" else DIAGNOSTICS_FILE
        val main = File(rootfs, path)
        val dir = main.parentFile ?: throw IOException("no diagnostics directory")
        if (!dir.isDirectory && !dir.mkdirs()) throw IOException("cannot create ${dir.path}")
        val file = if (manual) File(dir, "diagnostics-manual.md") else main
        val temp = File(dir, ".${file.name}.dsh-tmp")
        try {
            temp.writeText(markdown)
            if (!temp.renameTo(file)) throw IOException("cannot replace ${file.path}")
        } finally {
            temp.delete()
        }
        return file
    }

    /** Global DSH instructions ($DSH_HOME/AGENTS.md); left alone once the user removes the marker. */
    fun writeAgentsMd(
        rootfs: File,
        phoneStorage: Boolean,
        phoneControl: Boolean = false,
        visualReplies: Boolean = true,
        directEngine: Boolean = false,
        nativeLocale: String = "zh-CN",
    ) {
        try {
            val file = File(rootfs, "root/.dsh/AGENTS.md")
            val source = file.takeIf { it.isFile } ?: GuestFiles.resolve(
                rootfs, "/root/.dsh/AGENTS.md", phoneRoot = PhoneStorage.GUEST_PATH,
            )
            val existing = source?.readText()
            if (Files.exists(file.toPath(), LinkOption.NOFOLLOW_LINKS) &&
                existing?.startsWith(AGENTS_MARKER) != true) return
            val english = nativeLocale == "en"
            val instructions = if (english) AGENTS_MD_EN else AGENTS_MD
            val environment = if (directEngine) {
                val directInstructions = if (english) {
                    instructions.replace(DIRECT_ENVIRONMENT_FROM_EN, DIRECT_ENVIRONMENT_TO_EN)
                } else {
                    // l10n:keep agent prompt
                    instructions.replace("Ubuntu 24.04 环境里（proot，免 Root）", "Ubuntu 24.04 运行环境里（引擎直接启动，bash/git/python/apt 工具仍经 proot）")
                }
                val pathNote = if (english) DIRECT_PATH_NOTE_EN else {
                    // l10n:keep agent prompt
                    "\n- 文件工具、会话目录、@ 引用、AGENTS 和 skills 使用同一个完整绝对路径；该路径在 shell 内也同名可见。旧的 `/root` 路径仍可用于文件工具。shell 的输出不改写，不要删除路径的前缀。\n"
                }
                directInstructions.replace("`/root/workspace`", "`${rootfs.canonicalPath}/root/workspace`") + pathNote
            } else instructions
            val text = environment.replace(
                "{STORAGE_LINE}",
                if (phoneStorage) {
                    if (english) STORAGE_GRANTED_EN else {
                        // l10n:keep agent prompt
                        "用户已授权访问手机存储：手机内部存储挂载在 `/sdcard`（`/root/手机存储` 是它的快捷方式；相册在 `/sdcard/DCIM`，下载在 `/sdcard/Download`）。改动或删除用户文件前先说明并确认；给用户的产出文件放到 `/sdcard/Download/DSH-Go/`。"
                    }
                } else {
                    if (english) STORAGE_UNAVAILABLE_EN else {
                        // l10n:keep agent prompt
                        "手机相册、下载等用户文件不在这个环境里，看不到；如需访问，请用户在 App 设置里打开「访问手机文件」。"
                    }
                },
            ) + (if (visualReplies) {
                if (english) DSH_UI_SECTION_EN else DSH_UI_SECTION
            } else "") + (if (phoneControl) {
                if (english) PhoneGuest.AGENTS_SECTION_EN else PhoneGuest.AGENTS_SECTION
            } else "") + (if (english) DIAGNOSTICS_SECTION_EN else DIAGNOSTICS_SECTION).replace(
                "{PATH}",
                if (directEngine) "${rootfs.canonicalPath}/root/.dsh/dsh-app/diagnostics.md"
                else "\$DSH_HOME/dsh-app/diagnostics.md",
            )
            file.parentFile?.mkdirs()
            // Resolve tawc tokens for reading only; atomic replacement keeps backups unchanged.
            if (existing != text) SafeMode.writeAtomic(file.canonicalFile, text)
        } catch (_: Exception) {
        }
    }

    /** glibc in the guest reads /etc/resolv.conf; Android has none, so mirror the active network's DNS. */
    fun writeResolvConf(context: Context, rootfs: File): DnsConfigReport =
        writeResolvConfFromNetwork(rootfs, {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            cm.getLinkProperties(cm.activeNetwork)?.dnsServers.orEmpty()
        }, Os::rename)

    internal fun writeResolvConfFromNetwork(
        rootfs: File,
        readNetwork: () -> List<InetAddress>,
        replace: (String, String) -> Unit,
    ): DnsConfigReport {
        var networkRead = DnsNetworkRead.READ
        val addresses = try {
            readNetwork().also { if (it.isEmpty()) networkRead = DnsNetworkRead.EMPTY }
        } catch (_: Exception) {
            networkRead = DnsNetworkRead.FAILED
            emptyList()
        }
        return writeResolvConf(rootfs, pickDns(addresses), replace).copy(networkRead = networkRead)
    }

    /** Up to two of the network's servers, IPv4 first, then the public fallbacks: three in all. */
    fun pickDns(addrs: List<InetAddress>): List<String> {
        val network = addrs.filterNot { it.isLinkLocalAddress }
            .sortedBy { if (it is Inet4Address) 0 else 1 }
            .mapNotNull { it.hostAddress?.substringBefore('%') }.distinct().take(2)
        return (network + FALLBACK_DNS).distinct().take(3)
    }

    fun writeResolvConf(rootfs: File, servers: List<String>): DnsConfigReport =
        writeResolvConf(rootfs, servers, Os::rename)

    internal fun writeResolvConf(
        rootfs: File,
        servers: List<String>,
        replace: (String, String) -> Unit,
    ): DnsConfigReport {
        val requested = servers.take(3).toList()
        val text = buildString {
            appendLine("# written by dsh-app from the device's active network")
            servers.forEach { appendLine("nameserver $it") }
            appendLine("options ${DnsConfigReport.OPTIONS}")
        }
        var stage = DnsConfigStage.PREPARE
        try {
            val etc = File(rootfs, "etc")
            if (!etc.isDirectory && !etc.mkdirs() && !etc.isDirectory) throw IOException("Cannot prepare resolver directory")
            val target = File(etc, "resolv.conf")
            stage = DnsConfigStage.READ
            if (target.isFile && target.readText() == text) return DnsConfigReport(DnsConfigOutcome.UNCHANGED, requested)
            // Swapped in whole while DSH runs; also replaces a symlink (e.g. to systemd-resolved) with a plain file.
            val temp = File(etc, ".resolv.conf.dsh-tmp")
            stage = DnsConfigStage.WRITE
            temp.writeText(text)
            stage = DnsConfigStage.REPLACE
            replace(temp.path, target.path)
            return DnsConfigReport(DnsConfigOutcome.WRITTEN, requested)
        } catch (e: Exception) {
            val error = when (e) {
                is ErrnoException -> DnsConfigError.NATIVE
                is SecurityException -> DnsConfigError.SECURITY
                is IOException -> DnsConfigError.IO
                else -> DnsConfigError.OTHER
            }
            return DnsConfigReport(DnsConfigOutcome.FAILED, requested, stage, error, (e as? ErrnoException)?.errno)
        }
    }
}
