#!/usr/bin/env python3
"""Build the iOS runtime from verified shared composition, without editing its inputs."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile

HELPER = 'runtime/ohos/process/build/just-bash/chunks/chunk-GN6CQ3J4.js'
PROVENANCE = 'runtime/ohos/process/build/just-bash/PROVENANCE.json'
PIN = '7703634b9ac323b0de2361790c055b9ec032ee1f71dd64a5248b549c39c35a9e'
# The shared rewrite (runtime/ohos/process/bash-src/rewrite.py) already encodes
# UTF-8 output through Buffer's latin1 view, which bounds the per-byte cons-string
# amplification iOS used to patch here. iOS takes the module as it is, and refuses
# a build that has lost that bound.
BOUNDED = 'return ohosBuffer.from(t,"utf8").toString("latin1")'

# The shared composition refuses every image, for want of a decoder on HarmonyOS. iOS has one,
# so the attachment store loads runtime/ios/image/ios-sharp.cjs in place of sharp. ImageIO can't
# write WebP, so alpha stays in PNG. Each has to match exactly once, or the build stops.
ATTACHMENTS = 'node_modules/@deepseek-ai/dsh-attachment-local/lib/index.js'
IMAGE_CODEC = 'node_modules/@deepseek-ai/dsh-attachment-local/lib/ios-sharp.cjs'
WORKER_ENV = 'runtime/ios/process/worker-env.mjs'
PRELOAD = 'runtime/ohos/preload.mjs'
RELOCATION_FILES = ('runtime/ios/storage/relocate.mjs', 'runtime/ios/storage/preload.mjs')
PRELOAD_BEFORE = "await import('./publication/preload.mjs');\n"
PRELOAD_AFTER = PRELOAD_BEFORE + "await import('../ios/storage/preload.mjs');\n"
# Keep platform diagnostics local to the iOS output; each exact edit must match once.
DIAGNOSTIC_EDITS = {
    'runtime/ohos/process/rg.mjs': (
        ('rg: 鸿蒙本机尚不支持', 'rg: iOS 本机尚不支持'),
    ),
    'runtime/ohos/process/commands.mjs': (
        ('这个命令在鸿蒙本机不可用，可以连接电脑执行', '这个命令在 iOS 本机不可用，可以连接电脑执行'),
    ),
    'runtime/ohos/process/git.mjs': (
        ('这个命令在鸿蒙本机不可用，可以连接电脑执行', '这个命令在 iOS 本机不可用，可以连接电脑执行'),
        ('(OHOS subset)', '(iOS subset)'),
    ),
    'runtime/ohos/process/rg-select.mjs': (
        ('遍历检查超过鸿蒙本机上限', '遍历检查超过 iOS 本机上限'),
        ('候选文件数超过鸿蒙本机上限', '候选文件数超过 iOS 本机上限'),
    ),
    'runtime/ohos/process/runtime.mjs': (
        ("import { randomUUID } from 'node:crypto';", "import { randomUUID } from 'node:crypto';\nimport { workerEnvironment } from '../../ios/process/worker-env.mjs';"),
        ("          const workerEnv = { ...env };", "          const workerEnv = workerEnvironment(env);"),
        ("prepare(argv, policy, signal) {\n    if (this.closed) throw new Error('鸿蒙虚拟进程服务已关闭')", "prepare(argv, policy, signal) {\n    if (this.closed) throw new Error('iOS 虚拟进程服务已关闭')"),
        ('鸿蒙本机没有 PTY，可以连接电脑执行', 'iOS 本机没有 PTY，可以连接电脑执行'),
        ("spawn(spec) {\n    if (this.closed) throw new Error('鸿蒙虚拟进程服务已关闭')", "spawn(spec) {\n    if (this.closed) throw new Error('iOS 虚拟进程服务已关闭')"),
        ('无效或已使用的鸿蒙执行票据', '无效或已使用的 iOS 执行票据'),
        ('鸿蒙虚拟进程临时根的身份已改变，拒绝删除替换目录', 'iOS 虚拟进程临时根的身份已改变，拒绝删除替换目录'),
    ),
    'runtime/ohos/process/child-process.mjs': (
        ('OS child processes are unavailable on OpenHarmony; use the virtual runtime or a remote service.', 'OS child processes are unavailable on iOS; use the virtual runtime or a remote service.'),
    ),
    'runtime/ohos/process/index.mjs': (
        ('鸿蒙虚拟进程后端只能由鸿蒙 profile 或仿真显式启用', 'iOS 虚拟进程后端只能由 iOS profile 或仿真显式启用'),
        ('鸿蒙虚拟进程无法保留完整输出', 'iOS 虚拟进程无法保留完整输出'),
    ),
    'runtime/ohos/process/sandbox.mjs': (
        ('鸿蒙沙箱后端只能由鸿蒙 profile 或仿真显式启用', 'iOS 沙箱后端只能由 iOS profile 或仿真显式启用'),
    ),
    'runtime/ohos/publication/index.mjs': (
        ('OpenHarmony publication requires Node', 'iOS publication requires Node'),
        ('OpenHarmony publication service is already registered', 'iOS publication service is already registered'),
        ('OpenHarmony publication linked binding is unavailable', 'iOS publication linked binding is unavailable'),
        ('OpenHarmony publication binding lacks required ownership operations', 'iOS publication binding lacks required ownership operations'),
        ('OpenHarmony publication requires an explicit valid DSH_HOME', 'iOS publication requires an explicit valid DSH_HOME'),
        ('OpenHarmony publication is using exclusive copy', 'iOS publication is using exclusive copy'),
    ),
    'node_modules/node-addon-native-custom-loader/lib/index.js': (
        ('OpenHarmony packages only the pinned N-API backend', 'iOS packages only the pinned N-API backend'),
    ),
    'node_modules/@dsh-go/ohos-native/index.cjs': (
        ("flock: 'libdsh_flock.so',", "flock: 'DshFlock.framework/DshFlock',"),
        ("'require-builtin': 'libdsh_require_builtin.so',", "'require-builtin': 'DshRequireBuiltin.framework/DshRequireBuiltin',"),
        ('// .so is the HAP library filename; require(.so) would parse it as JavaScript.',
         '// Framework executables are fixed native addons, loaded explicitly with process.dlopen.'),
        ('This native product is not packaged for OpenHarmony', 'This native product is not packaged for iOS'),
    ),
    'node_modules/proxy-agent-negotiate/dist/index.js': (
        ('鸿蒙不提供 Kerberos 原生认证', 'iOS 不提供 Kerberos 原生认证'),
    ),
    'node_modules/@deepseek-ai/dsh-office-to-pdf/lib/index.js': (
        ('鸿蒙本机不支持 Office 转换', 'iOS 本机不支持 Office 转换'),
    ),
    'node_modules/@deepseek-ai/dsh-tool-fs-search/lib/index.js': (
        ('鸿蒙搜索需要提供受限执行票据的 subprocess 后端', 'iOS 搜索需要提供受限执行票据的 subprocess 后端'),
        ('鸿蒙本机不读取全局 gitignore 或 core.excludesFile', 'iOS 本机不读取全局 gitignore 或 core.excludesFile'),
    ),
    'node_modules/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js': (
        ('OpenHarmony publication preload is required', 'iOS publication preload is required'),
        ('OpenHarmony session storage must run in the main Node thread', 'iOS session storage must run in the main Node thread'),
    ),
    'node_modules/@deepseek-ai/dsh-attachment-local/lib/index.js': (
        ('OpenHarmony publication preload is required', 'iOS publication preload is required'),
    ),
    'node_modules/@deepseek-ai/dsh-tool-bash/lib/index.js': (
        ('鸿蒙本机使用虚拟 shell', 'iOS 本机使用虚拟 shell'),
    ),
    'node_modules/@deepseek-ai/dsh-skill-office/lib/index.js': (
        ('鸿蒙本机不提供 LibreOffice 转换、重算或渲染运行时', 'iOS 本机不提供 LibreOffice 转换、重算或渲染运行时'),
    ),
    'node_modules/@deepseek-ai/dsh-experimental-speech-to-text-sensevoice/lib/index.js': (
        ('鸿蒙本机不提供 Sherpa 语音模型', 'iOS 本机不提供 Sherpa 语音模型'),
    ),
    'node_modules/@deepseek-ai/dsh-plugin-manager/lib/index.js': (
        ('鸿蒙本机不支持安装、更新或卸载插件包', 'iOS 本机不支持安装、更新或卸载插件包'),
    ),
    'node_modules/@deepseek-ai/dsh-plugin-manager/lib/types/operations.js': (
        ('鸿蒙本机不支持安装、更新或卸载插件包', 'iOS 本机不支持安装、更新或卸载插件包'),
    ),
    'runtime/ohos/process/git-index.mjs': (
        ('OHOS Git currently supports index version 2 and 3', 'iOS Git currently supports index version 2 and 3'),
    ),
    'runtime/ohos/process/node-worker-paths.mjs': (
        ('child_process is unavailable in the OHOS Node script Worker', 'child_process is unavailable in the iOS Node script Worker'),
    ),
    'runtime/ohos/process/node-script.mjs': (
        ("import { Worker } from 'node:worker_threads';", "import { Worker } from 'node:worker_threads';\nimport { workerEnvironment } from '../../ios/process/worker-env.mjs';"),
        ("    argv, env, stdin: streamStdin, stdout: true, stderr: true,", "    argv, env: workerEnvironment(env), stdin: streamStdin, stdout: true, stderr: true,"),
        ('Node scripts require the inherited OHOS product preload', 'Node scripts require the inherited iOS product preload'),
    ),
    'runtime/ohos/net/bootstrap.mjs': (
        ('OHOS network bootstrap requires the locked DSH 0.2.2-rc.1 entry with Undici 8.11.2', 'iOS network bootstrap requires the locked DSH 0.2.2-rc.1 entry with Undici 8.11.2'),
        ('OHOS network bootstrap was initialized for another DSH entry', 'iOS network bootstrap was initialized for another DSH entry'),
        ('OHOS DSH network preload must run before the first Undici/global-dispatcher API import', 'iOS DSH network preload must run before the first Undici/global-dispatcher API import'),
    ),
    'node_modules/@deepseek-ai/dsh-http-proxy/lib/index.js': (
        ('OHOS network preload is required', 'iOS network preload is required'),
        ('OHOS DSH network bootstrap is required before proxy installation', 'iOS DSH network bootstrap is required before proxy installation'),
    ),
    'node_modules/@deepseek-ai/dsh-workspace-changes/lib/index.js': (
        ('OHOS workspace snapshots require the subprocess private temporaryRoot', 'iOS workspace snapshots require the subprocess private temporaryRoot'),
    ),
    'node_modules/@deepseek-ai/dsh-web-fetch-http/lib/index.js': (
        ('OHOS network preload is required', 'iOS network preload is required'),
    ),
}
ATTACHMENT_EDITS = (
    ('* Establish this process\'s proof that one DSH_HOME entry and every ancestor\n* below the filesystem root (or installed Direct root) are durable.',
     '* Sync the native iOS default DSH_HOME entry within its host-owned HOME.\n* Custom store homes retain the original Direct/filesystem-root boundary.'),
    # The native host owns HOME and validates the default DSH_HOME = HOME/.dsh.
    # Keep main's Direct-root boundary for any custom home instead of syncing
    # container ancestors that the iOS app is not permitted to open.
    ('\t\tconst boundary = typeof directRoot === "string" && (home === directRoot || home.startsWith(directRoot + "/")) ? directRoot : parse(home).root;',
     '\t\tconst hostHome = process.env.HOME;\n'
     '\t\tconst boundary = hostHome && resolve(hostHome) === hostHome && home === join(hostHome, ".dsh") && home === resolveDshHome() ? hostHome : typeof directRoot === "string" && (home === directRoot || home.startsWith(directRoot + "/")) ? directRoot : parse(home).root;'),
    ('const loadSharp = createLazyRequire("sharp", import.meta.url);',
     'const loadSharp = createLazyRequire("./ios-sharp.cjs", import.meta.url);'),
    ('\tif (process.platform === "openharmony") throw new AttachmentError("鸿蒙本机尚无可用的图像解码/重编码库；请连接电脑处理图像。普通文件仍可上传或保存。", "OHOS_IMAGE_CODEC_UNAVAILABLE");\n',
     ''),
    ('const mediaType = hasAlpha ? "image/webp" : "image/jpeg";',
     'const mediaType = hasAlpha ? "image/png" : "image/jpeg";'),
    ('(mediaType === "image/webp" ? pipeline.webp({\n\t\tquality,\n\t\teffort: 0\n\t}) : pipeline.jpeg({ quality }))',
     '(mediaType === "image/png" ? pipeline.png() : pipeline.jpeg({ quality }))'),
    # PNG has no quality ladder: repeat encodes would produce the same pixels and bytes.
    ('return IMAGE_ENCODING_QUALITIES.map((quality) => (() => encode(prepared.clone(), mediaType, quality)));',
     'return (hasAlpha ? IMAGE_ENCODING_QUALITIES.slice(0, 1) : IMAGE_ENCODING_QUALITIES).map((quality) => (() => encode(prepared.clone(), mediaType, quality)));'),
)


def attachments_for_ios(original):
    text = original.decode()
    for before, after in ATTACHMENT_EDITS:
        if text.count(before) != 1:
            raise ValueError('iOS attachment edit differs from the composed store: ' + before[:60])
        text = text.replace(before, after)
    # Node reports OpenHarmony on iOS for the shared runtime. Keep its atomic
    # publication path while sending images through the ImageIO-backed shim.
    publication_gates = (
        'if (process.platform === "openharmony") await publishOhosExclusive(source, target);',
        'if (process.platform === "openharmony") await publishOhosExclusive(staged.path, target);',
    )
    for index, gate in enumerate(publication_gates):
        if text.count(gate) != 1:
            raise ValueError('iOS publication route differs from the composed store')
        text = text.replace(gate, f'__DSH_IOS_PUBLICATION_GATE_{index}__')
    image_gate = 'process.platform === "openharmony"'
    if text.count(image_gate) != 12:
        raise ValueError('iOS image routes differ from the composed store')
    text = text.replace(image_gate, 'false')
    for index, gate in enumerate(publication_gates):
        text = text.replace(f'__DSH_IOS_PUBLICATION_GATE_{index}__', gate)
    return text.encode()


# Activity budgets are specialized only in the iOS output. Shared inputs stay intact.
ACTIVITY_CLOCK = 'runtime/ios/lifecycle/clock.mjs'
ACTIVITY_EDITS = {
    'runtime/ohos/lifecycle/budget.mjs': (
        ("import { performance } from 'node:perf_hooks';", "import { activeNow } from '../../ios/lifecycle/clock.mjs';"),
        (" * Only explicit, confirmed logical pauses in this process affect this clock.\n * Unannounced SIGSTOP, busy CPU and delayed callbacks remain elapsed budget.",
         " * iOS activity time also excludes native-detected scheduling gaps.\n * Confirmed logical pauses are measured in the same adjusted time domain."),
        ('this.#pauseStart ?? performance.now()', 'this.#pauseStart ?? activeNow()'),
        ('this.#pauseStart = performance.now();', 'this.#pauseStart = activeNow();'),
        ('this.#excluded += performance.now() - this.#pauseStart;', 'this.#excluded += activeNow() - this.#pauseStart;'),
        ('// Without a confirmed pause, elapsed monotonic time is still charged.',
         '// Without a confirmed pause, elapsed iOS activity time is still charged.'),
    ),
    'node_modules/@deepseek-ai/dsh-jobs-local/lib/index.js': (
        ('\t\t\t\t\td.signal.addEventListener("abort", onAbort, { once: true });',
         '\t\t\t\t\tif (d.signal.aborted) onAbort();\n\t\t\t\t\telse d.signal.addEventListener("abort", onAbort, { once: true });'),
    ),
    'node_modules/@deepseek-ai/dsh-timeout/lib/index.js': (
        ('code === "TOOL_TIMEOUT" || code === "BASH_TIMEOUT"',
         'code === "TOOL_TIMEOUT" || code === "BASH_TIMEOUT" || code === "TASK_WAIT_TIMEOUT"'),
    ),
}


def activity_for_ios(name, original):
    data = original
    for before, after in ACTIVITY_EDITS[name]:
        before, after = before.encode(), after.encode()
        if data.count(before) != 1:
            raise ValueError('iOS activity edit differs from composed input: ' + name)
        data = data.replace(before, after)
    return data


def diagnostics_for_ios(name, original):
    data = original
    for before, after in DIAGNOSTIC_EDITS[name]:
        before, after = before.encode(), after.encode()
        if data.count(before) != 1:
            raise ValueError('iOS diagnostic differs from composed input: ' + name)
        data = data.replace(before, after)
    return data


def specialize(expanded, out, composer):
    expanded = expanded.resolve(strict=True)
    output = out.resolve()
    if output.is_relative_to(expanded) or expanded.is_relative_to(output):
        raise ValueError('iOS output must be separate from the shared expanded input')
    if out.exists() or out.is_symlink():
        raise ValueError('iOS output already exists; preserved')
    original = (expanded / 'files' / HELPER).read_bytes()
    if hashlib.sha256(original).hexdigest() != PIN or original.decode().count(BOUNDED) != 1:
        raise ValueError('iOS byte encoder differs from pinned just-bash 3.6.0 input')
    manifest = json.loads((expanded / 'manifest.json').read_bytes())
    entries = {row['path']: row for row in manifest['files']}
    attachments = attachments_for_ios((expanded / 'files' / ATTACHMENTS).read_bytes())
    activity = {name: activity_for_ios(name, (expanded / "files" / name).read_bytes())
                for name in ACTIVITY_EDITS}
    clock = (Path(__file__).resolve().parents[2] / ACTIVITY_CLOCK).read_bytes()
    diagnostics = {}
    for name in DIAGNOSTIC_EDITS:
        data = attachments if name == ATTACHMENTS else (expanded / 'files' / name).read_bytes()
        diagnostics[name] = diagnostics_for_ios(name, data)
    guest_spec = importlib.util.spec_from_file_location('ios_guest_specialization', Path(__file__).with_name('guest-specialization.py'))
    guest = importlib.util.module_from_spec(guest_spec)
    guest_spec.loader.exec_module(guest)
    for name, anchors in guest.INPUT_GUARDS.items():
        data = (expanded / 'files' / name).read_bytes()
        if entries[name]['sha256'] != composer.digest(data) or entries[name]['size'] != len(data):
            raise ValueError('iOS guest owner input differs from shared manifest: ' + name)
        for anchor in anchors:
            if data.count(anchor.encode()) != 1:
                raise ValueError('iOS guest cleanup owner API differs from pinned source: ' + name)
    guest_overrides = {}
    guest_mapping = {}
    for name in guest.EDITS:
        data = diagnostics.get(name, (expanded / 'files' / name).read_bytes())
        target = 'runtime/ios/guest/overrides/' + name
        guest_mapping[name] = target
        guest_overrides[target] = guest.specialize(name, data)
    codec = (Path(__file__).resolve().parents[2] / 'runtime/ios/image/ios-sharp.cjs').read_bytes()
    worker_env = (Path(__file__).resolve().parents[2] / WORKER_ENV).read_bytes()
    relocation = {name: (Path(__file__).resolve().parents[2] / name).read_bytes()
                  for name in (*RELOCATION_FILES, *guest.FILES)}
    preload = (expanded / 'files' / PRELOAD).read_text()
    if preload.count(PRELOAD_BEFORE) != 1 or '../ios/storage/preload.mjs' in preload:
        raise ValueError('iOS relocation preload differs from the shared input')
    guest_preload = (Path(__file__).with_name('guest-preload.js.txt')).read_text()
    guest_boot = preload.replace(PRELOAD_BEFORE, PRELOAD_AFTER + guest_preload)
    preload = preload.replace(PRELOAD_BEFORE, PRELOAD_AFTER).encode()
    relocation.update(guest_overrides)
    relocation['runtime/ios/guest/overrides.json'] = composer.json_bytes(guest_mapping)
    relocation['runtime/ohos/preload-guest.mjs'] = ("await import('../ios/guest/overrides.mjs');\n" + guest_boot).encode()
    for name in (HELPER, PROVENANCE, ATTACHMENTS, PRELOAD, *DIAGNOSTIC_EDITS, *guest.EDITS):
        data = (expanded / 'files' / name).read_bytes()
        if entries[name]['sha256'] != composer.digest(data) or entries[name]['size'] != len(data):
            raise ValueError('iOS specialization input differs from shared manifest: ' + name)
    for name in ACTIVITY_EDITS:
        data = (expanded / 'files' / name).read_bytes()
        if entries[name]['sha256'] != composer.digest(data) or entries[name]['size'] != len(data):
            raise ValueError('iOS specialization input differs from shared manifest: ' + name)
    if ACTIVITY_CLOCK in entries:
        raise ValueError('The shared composition already has an iOS activity clock')
    provenance = json.loads((expanded / 'files' / PROVENANCE).read_bytes())
    module = 'chunks/chunk-GN6CQ3J4.js'
    if provenance['upstream']['version'] != '3.6.0' or provenance['modules'][module] != PIN:
        raise ValueError('Unexpected just-bash provenance')
    changed = original
    provenance['iosSpecialization'] = {
        'reason': 'None: the shared just-bash build already bounds UTF-8 byte-string output',
        'beforeSha256': PIN, 'afterSha256': composer.digest(changed),
        'generatorSha256': composer.digest(Path(__file__).read_bytes()),
    }
    out.parent.mkdir(parents=True, exist_ok=True)
    # Atomic publication of a separate generated tree/archive. Shared composition
    # and npm prefixes remain byte-for-byte unchanged, including failure paths.
    with tempfile.TemporaryDirectory(prefix='.ios-runtime-', dir=out.parent) as temp:
        stage = Path(temp) / 'result'
        tree = stage / 'expanded/dsh-runtime'
        shutil.copytree(expanded, tree)
        for name, data in {IMAGE_CODEC: codec, WORKER_ENV: worker_env, **relocation}.items():
            if name in entries:
                raise ValueError('The shared composition already has an iOS-only file: ' + name)
            row = {'path': name, 'size': len(data), 'sha256': composer.digest(data)}
            entries[name] = row
            manifest['files'].append(row)
            (tree / 'files' / name).parent.mkdir(parents=True, exist_ok=True)
            (tree / 'files' / name).write_bytes(data)
        manifest['files'].sort(key=lambda item: item['path'])
        for name, data in ((HELPER, changed), (PROVENANCE, composer.json_bytes(provenance)), (ATTACHMENTS, attachments),
                           (PRELOAD, preload), *diagnostics.items()):
            (tree / 'files' / name).write_bytes(data)
            entries[name]['sha256'] = composer.digest(data)
            entries[name]['size'] = len(data)
        clock_row = {'path': ACTIVITY_CLOCK, 'size': len(clock), 'sha256': composer.digest(clock)}
        entries[ACTIVITY_CLOCK] = clock_row
        manifest['files'].append(clock_row)
        manifest['files'].sort(key=lambda item: item['path'])
        clock_path = tree / 'files' / ACTIVITY_CLOCK
        clock_path.parent.mkdir(parents=True, exist_ok=True)
        clock_path.write_bytes(clock)
        for name, data in activity.items():
            (tree / 'files' / name).write_bytes(data)
            entries[name]['sha256'] = composer.digest(data)
            entries[name]['size'] = len(data)
        identity = composer.digest(composer.json_bytes({
            'target': 'ios', 'dsh': manifest['dshVersion'],
            'node': manifest['nodeVersion'], 'files': manifest['files'],
        }))
        manifest['runtimeVersion'] = 'ios-' + identity[:24]
        (tree / 'manifest.json').write_bytes(composer.json_bytes(manifest))
        # Reuse the existing ZIP32 constraints and full member/hash round trip.
        archive = composer.write_runtime_archive(tree, stage / 'runtime.zip')
        (stage / 'ios-report.json').write_bytes(composer.json_bytes({
            'schema': 1, 'runtimeVersion': manifest['runtimeVersion'],
            'inputManifestSha256': composer.digest((expanded / 'manifest.json').read_bytes()),
            'specialization': provenance['iosSpecialization'], 'archive': archive,
        }))
        stage.rename(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--expanded', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    spec = importlib.util.spec_from_file_location('shared_composition', root / 'runtime/ohos/package/compose-runtime.py')
    composer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(composer)
    specialize(args.expanded, args.out, composer)


if __name__ == '__main__':
    main()
