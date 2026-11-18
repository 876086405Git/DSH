#!/usr/bin/env python3
"""核对收录字节与固定闭包；不会把已记录的 BLOCKED 当成发行通过。"""
import argparse
import hashlib
import json
import pathlib
import re
import sys
import urllib.request


def digest(data):
    return hashlib.sha256(data).hexdigest()


def fixed_file(path, expected_hash, expected_size=None):
    data = path.read_bytes()
    assert digest(data) == expected_hash, f'SHA-256 不同：{path}'
    if expected_size is not None:
        assert len(data) == expected_size, f'字节数不同：{path}'
    return data


def dependency_paths(lock, roots):
    entries = lock['packages']

    def resolve(from_path, name):
        parent = pathlib.PurePosixPath(from_path)
        candidates = [parent, *parent.parents] if from_path else [pathlib.PurePosixPath('.')]
        for base in candidates:
            candidate = str(base / 'node_modules' / name)
            if candidate in entries:
                return candidate
        raise AssertionError(f'非可选依赖无法解析：{from_path} -> {name}')

    queue = [resolve('', name) for name in roots]
    visited = set()
    while queue:
        key = queue.pop()
        if key in visited:
            continue
        visited.add(key)
        entry = entries[key]
        names = set(entry.get('dependencies', {})) - set(entry.get('optionalDependencies', {}))
        for name in entry.get('peerDependencies', {}):
            if not entry.get('peerDependenciesMeta', {}).get(name, {}).get('optional', False):
                names.add(name)
        queue.extend(resolve(key, name) for name in names)
    return visited


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--process-prefix', required=True, type=pathlib.Path,
                        help='含已锁定 node_modules 的 process 依赖目录；只读')
    parser.add_argument('--esbuild-prefix', required=True, type=pathlib.Path,
                        help='含 esbuild 0.27.3 / @esbuild/linux-x64 的构建工具目录；只读')
    parser.add_argument('--fetch-sources', action='store_true',
                        help='重新读取清单中的 5 个公开许可 URL 并核摘要；不下载第三方实现')
    parser.add_argument('--require-complete', action='store_true',
                        help='存在已记录的发布缺项时退出 2；默认只检验收录的准确性')
    args = parser.parse_args()
    here = pathlib.Path(__file__).resolve().parent
    manifest = json.loads((here / 'manifest.json').read_text())
    process_dir = here.parent / 'process'
    package = json.loads(fixed_file(process_dir / 'package.json', manifest['processManifestSHA256']))
    lock = json.loads(fixed_file(process_dir / 'package-lock.json', manifest['processLockSHA256']))
    assert package['dependencies']['re2js'] == '1.3.3'
    assert lock['packages']['']['dependencies'] == package['dependencies']
    paths = dependency_paths(lock, manifest['roots'])
    assert paths == {item['path'] for item in manifest['packages']}
    assert len(paths) == manifest['packageCount'] == 91

    declared_documents = {item['path']: item for item in manifest['documents']}
    assert len(declared_documents) == len(manifest['documents']), '重复通知路径'
    by_package = {item['name']: item for item in manifest['packages']}

    # 明确的源内嵌入反例不能仅靠 LICENSE/NOTICE 文件名枚举发现。
    # 这里只固定已核的 Angular 两处来源，不宣称通用扫描可穷尽许可。
    angular_paths = {
        'texts/mixmark-io--domino-2.2.0/ANGULAR-LICENSE.txt',
        'texts/mixmark-io--domino-2.2.0/ANGULAR-STYLE-PARSER-NOTICE.txt',
        'texts/just-bash-3.6.0/ANGULAR-BUNDLED-NOTICE.txt',
    }
    angular = [item for item in manifest['embeddedComponents']
               if item.get('id') == 'angular-style-parser']
    assert len(angular) == 1, '遗漏已知 Angular 源内组件'
    assert set(angular[0]['documents']) == angular_paths, 'Angular 通知引用不完整'
    assert angular_paths <= declared_documents.keys(), '遗漏已知 Angular 通知文本'
    angular_terms = declared_documents['texts/mixmark-io--domino-2.2.0/ANGULAR-LICENSE.txt']
    assert angular_terms['sha256'] == '1d65ce0e0d6f0f237eeeb8fa186402ec8c6169d05ddadac6bcf9fa683eb5b34b'
    assert angular_terms['source']['url'] == 'https://raw.githubusercontent.com/angular/angular/92e41e9cb417223d9888a4c23b4c0e73188f87d0/LICENSE'
    for path, source_path, identity in [
        ('texts/mixmark-io--domino-2.2.0/ANGULAR-STYLE-PARSER-NOTICE.txt',
         'node_modules/@mixmark-io/domino/lib/style_parser.js',
         'b41b215a146a119303d052223216207ca4cbc48a14b122eda966094a56610f10'),
        ('texts/just-bash-3.6.0/ANGULAR-BUNDLED-NOTICE.txt',
         'node_modules/just-bash/dist/bin/chunks/chunk-DTGQQKI2.js',
         '1da8061bec7f16f2ca625c36d5c4daf8810148627e9bda9fdf6a396ac8f184f7'),
    ]:
        source = declared_documents[path]['source']
        assert source['kind'] == 'process-prefix' and source['path'] == source_path
        assert source['sha256'] == identity and 'byteRange' in source
    assert angular_paths - {'texts/just-bash-3.6.0/ANGULAR-BUNDLED-NOTICE.txt'} <= set(by_package['@mixmark-io/domino']['documents'])
    assert 'texts/just-bash-3.6.0/ANGULAR-BUNDLED-NOTICE.txt' in by_package['just-bash']['documents']

    apache = 'texts/clean-git-ref-2.0.1/APACHE-2.0.txt'
    assert apache in manifest['standardTerms'] and apache in by_package['clean-git-ref']['documents']
    assert declared_documents[apache]['sha256'] == 'cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30'
    assert declared_documents[apache]['source']['url'] == 'https://www.apache.org/licenses/LICENSE-2.0.txt'
    assert by_package['clean-git-ref']['registration'] == 'DECLARED_APACHE_STANDARD_AND_EXISTING_ATTRIBUTION_RECORDED'
    assert by_package['minimisted']['registration'] == 'BLOCKED_MISSING_CORRESPONDING_NOTICE'

    originals = set()
    for item in manifest['packages']:
        location = args.process_prefix / item['path']
        installed = json.loads(fixed_file(location / 'package.json', item['packageJSONSHA256']))
        assert installed['name'] == item['name'] and installed['version'] == item['version']
        assert installed.get('license') == item['declaredLicense']
        for key in ['version', 'resolved', 'integrity']:
            assert lock['packages'][item['path']].get(key) == item.get(key)
        assert item['documents'], f'包没有登记文本：{item["name"]}'
        assert set(item['documents']) <= declared_documents.keys()
        if item['name'] in {'clean-git-ref', 'minimisted'}:
            assert item['attributionFields'] == {key: installed[key] for key in ['author', 'license']}
        if item['name'] == 'clean-git-ref':
            distribution = {str(file.relative_to(args.process_prefix)): file
                            for file in location.rglob('*') if file.is_file()}
            assert set(distribution) == {row['path'] for row in item['distributionFiles']}
            for row in item['distributionFiles']:
                fixed_file(distribution[row['path']], row['sha256'], row['bytes'])
        for file in location.rglob('*'):
            if file.is_file() and re.search(r'licen[cs]e|notice|authors|copyright|copying', file.name, re.I):
                originals.add(str(file.relative_to(args.process_prefix)))

    collected = set()
    network = 0
    ranges = 0
    for doc in manifest['documents']:
        output = fixed_file(here / doc['path'], doc['sha256'], doc['bytes'])
        source = doc['source']
        if source['kind'] == 'public-url':
            if not args.fetch_sources:
                assert 'byteRange' not in source
                assert source['sha256'] == doc['sha256'] and source['bytes'] == doc['bytes']
                continue
            request = urllib.request.Request(source['url'], headers={'User-Agent': 'dsh-go-notice-verification'})
            try:
                with urllib.request.urlopen(request, timeout=30) as response:
                    original = response.read()
            except OSError as error:
                raise OSError(f'公开来源读取失败：{source["url"]}：{error}') from error
            assert digest(original) == source['sha256'] and len(original) == source['bytes']
            network += 1
        else:
            assert source['kind'] in {'process-prefix', 'esbuild-prefix'}
            prefix = args.process_prefix if source['kind'] == 'process-prefix' else args.esbuild_prefix
            original = fixed_file(prefix / source['path'], source['sha256'], source['bytes'])
            if source['kind'] == 'process-prefix' and 'byteRange' not in source:
                collected.add(source['path'])
        if 'byteRange' in source:
            start, end = source['byteRange']
            assert 0 <= start <= end <= len(original)
            original = original[start:end]
            ranges += 1
        assert original == output, f'收录文本与来源不同：{doc["path"]}'
    assert originals <= collected, f'遗漏许可文件：{sorted(originals - collected)}'
    assert len(originals) == 94
    declared_outputs = {doc['path'] for doc in manifest['documents']}
    actual_outputs = {str(path.relative_to(here)) for path in (here / 'texts').rglob('*') if path.is_file()}
    assert declared_outputs == actual_outputs
    for item in manifest['buildTools']:
        data = json.loads((args.esbuild_prefix / 'node_modules' / item['name'] / 'package.json').read_text())
        assert data['name'] == item['name'] and data['version'] == item['version'] == '0.27.3'
        assert data['license'] == item['declaredLicense'] == 'MIT'

    blockers = manifest['blockers']
    assert {item['id'] for item in blockers} == {'minimisted-terms', 'cpython-embedded-notices'}
    assert all(item['status'] == 'BLOCKED' for item in blockers)
    report = {
        'noticeBytesAndClosure': 'PASS',
        'runtimePackages': len(paths),
        'originalLicenseFilesPreserved': len(originals),
        'documents': len(manifest['documents']),
        'sourceExcerpts': ranges,
        'publicSourcesRefetched': network,
        'publicSourceMode': 'REFETCHED' if args.fetch_sources else 'RECORDED_HASH_ONLY',
        'buildTools': len(manifest['buildTools']),
        'knownAngularSourceNotices': 2,
        'embeddedSourcesExhaustivelyAudited': False,
        'publisherMetadataRetained': ['clean-git-ref', 'minimisted'],
        'releaseStatus': 'BLOCKED',
        'blockers': [item['id'] for item in blockers],
        'finalHapVerification': 'NOT_RUN',
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 2 if args.require_complete else 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (AssertionError, OSError, ValueError) as error:
        print(f'通知核对失败：{error}', file=sys.stderr)
        sys.exit(1)
