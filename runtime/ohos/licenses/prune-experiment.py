#!/usr/bin/env python3
"""只在新建 shadow 中测量候选裁剪；不修改源 prefix 或产品打包规则。"""
import argparse
import hashlib
import json
import os
import pathlib
import shutil
import subprocess


def sha(data):
    return hashlib.sha256(data).hexdigest()


def files(directory):
    result = []
    for file in sorted(directory.rglob('*')):
        if file.is_file():
            data = file.read_bytes()
            result.append({'path': str(file.relative_to(directory)), 'bytes': len(data), 'sha256': sha(data)})
    return result


def save(directory, name, value):
    (directory / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['process-prefix', 'process-source', 'dsh-prefix', 'regex-artifact', 'sim-preload', 'node', 'output']:
        parser.add_argument('--' + name, required=True, type=pathlib.Path)
    args = parser.parse_args()
    here = pathlib.Path(__file__).resolve().parent
    manifest = json.loads((here / 'manifest.json').read_text())
    args.output.mkdir(parents=True, exist_ok=False)
    out = args.output.resolve()
    shadow = out / 'shadow'
    mods = shadow / 'node_modules'
    mods.mkdir(parents=True)
    report = {'scope': '独立 shadow 功能子集的裁剪实验；不是最终 HAP/O2 验收', 'node': str(args.node), 'stages': []}
    version = subprocess.check_output([str(args.node), '--version'], text=True).strip()
    assert version == 'v24.22.1', version
    report['nodeVersion'] = version
    report['preload'] = {'path': str(args.sim_preload.resolve()), 'sha256': sha(args.sim_preload.read_bytes())}
    report['regexSHA256'] = sha(args.regex_artifact.read_bytes())
    assert report['regexSHA256'] == '80eaea2a9e50a2851e332fa4fccffeb01550584ad3c448a2eadd88b43373d5f1'
    before = {}
    for package in manifest['packages']:
        source = args.process_prefix / package['path']
        destination = shadow / package['path']
        destination.parent.mkdir(parents=True, exist_ok=True)
        before[package['path']] = files(source)
        shutil.copytree(source, destination, symlinks=True)
        for file in before[package['path']]:
            original = source / file['path']
            copied = destination / file['path']
            assert (original.stat().st_dev, original.stat().st_ino) != (copied.stat().st_dev, copied.stat().st_ino)
    save(out, 'original-file-hashes.json', before)
    shutil.copytree(args.process_source, shadow / 'process', ignore=shutil.ignore_patterns('node_modules', 'build', '__pycache__'))
    process_sources = files(shadow / 'process')
    save(out, 'process-source-files.json', process_sources)
    report['processSource'] = str(args.process_source.resolve())
    report['processSourceFileListSHA256'] = sha(json.dumps(process_sources, sort_keys=True, separators=(',', ':')).encode())
    report['copiedPackages'] = len(manifest['packages'])
    report['copiedFileBytes'] = sum(item['bytes'] for listing in before.values() for item in listing)
    (shadow / 'process/node_modules').symlink_to('../node_modules')
    (mods / '@deepseek-ai').symlink_to(args.dsh_prefix.resolve() / 'node_modules/@deepseek-ai')
    (shadow / 'process/build').mkdir()
    shutil.copyfile(args.regex_artifact, shadow / 'process/build/re2js-unicode.mjs')
    report['externalReadOnlyDSHNamespace'] = str(args.dsh_prefix.resolve() / 'node_modules/@deepseek-ai')
    tests = here.parent.parent / 'tests/ohos'
    report['probeSHA256'] = {name: sha((tests / name).read_bytes()) for name in ['licenses-prune-probe.mjs', 'licenses-sqlite-probe.mjs']}
    argv = [str(args.node), '--jitless', '--import', str(args.sim_preload.resolve()), str(tests / 'licenses-prune-probe.mjs')]
    env = dict(os.environ, M4_LICENSE_SHADOW=str(shadow), DSH_GO_OHOS_SIM='1', DSH_GO_OHOS_SIM_PLATFORM='openharmony')
    report['argv'] = argv
    removed = []
    stages = [('complete-closure', []), ('no-typescript-sql', ['node_modules/typescript', 'node_modules/sql.js']), ('no-typescript-sql-cpython', ['node_modules/just-bash/vendor/cpython-emscripten'])]
    for stage, paths in stages:
        for relative in paths:
            target = shadow / relative
            assert target.is_dir() and not target.is_symlink() and target.resolve().is_relative_to(shadow)
            listing = files(target)
            removed.append({'stage': stage, 'path': relative, 'bytes': sum(item['bytes'] for item in listing), 'files': listing})
            shutil.rmtree(target)
        env['M4_PRUNE_STAGE'] = stage
        result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=90)
        (out / (stage + '.stdout')).write_text(result.stdout)
        (out / (stage + '.stderr')).write_text(result.stderr)
        record = {'stage': stage, 'processExitCode': result.returncode, 'result': json.loads(result.stdout)}
        report['stages'].append(record)
        save(out, 'report.json', report)
        assert result.returncode == 0 and record['result']['pass'] == 8, record
    save(out, 'removed-files.json', removed)

    sqlite = []
    for stage, prefix in [('original', args.process_prefix / 'node_modules/just-bash'), ('pruned-shadow', mods / 'just-bash')]:
        env = dict(os.environ, M4_BASH_ROOT=str(prefix.resolve()))
        result = subprocess.run([str(args.node), str(tests / 'licenses-sqlite-probe.mjs')], env=env, capture_output=True, text=True, timeout=30)
        sqlite.append({'stage': stage, 'processExitCode': result.returncode, 'result': json.loads(result.stdout), 'stderr': result.stderr})
    save(out, 'sqlite-esm-boundary.json', sqlite)
    assert sqlite[0]['result']['exitCode'] == 0 and sqlite[0]['result']['stdout'] == '1\n'
    assert sqlite[1]['result']['exitCode'] == 1 and 'sql.js' in sqlite[1]['result']['stderr']
    for package in manifest['packages']:
        assert before[package['path']] == files(args.process_prefix / package['path']), package['path']
    report.update(sourceFilesUnchanged=True, noSharedFileInodes=True, removedBytes=sum(item['bytes'] for item in removed), finalHap='NOT_RUN', sqliteEnabledAfterPruning='UNAVAILABLE_AS_EXPECTED')
    # 只回收本次新建目录中自己复制的依赖；保留全部报告、精确文件清单。
    shutil.rmtree(shadow)
    report['shadowRemoved'] = True
    save(out, 'report.json', report)
    print(json.dumps({key: report[key] for key in ['nodeVersion', 'sourceFilesUnchanged', 'noSharedFileInodes', 'removedBytes', 'finalHap', 'sqliteEnabledAfterPruning', 'shadowRemoved']}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
