#!/usr/bin/env python3
import argparse
import ast
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import tempfile
from types import SimpleNamespace
import unittest
import warnings
import zipfile
import zlib
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location('runtime_archive_audit', ROOT / 'tooling/ohos/runtime_archive_audit.py')
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


def member(name, data, method):
    info = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
    info.create_system = 3
    info.external_attr = 0o100644 << 16
    return info, data, method


def pack(items):
    output = io.BytesIO()
    with warnings.catch_warnings(), zipfile.ZipFile(output, 'w', allowZip64=False) as archive:
        warnings.simplefilter('ignore', UserWarning)
        for info, data, method in items:
            archive.writestr(info, data, compress_type=method, compresslevel=9 if method == 8 else None)
    return output.getvalue()


def inner(files=None, change_manifest=None, extra=(), omit=()):
    # Every non-contract test starts from a manifest accepted by the actual
    # Host/Core entry contract. A missing entry must not mask its intended fault.
    payload = {name: b'fixture' for name in AUDIT.required_entries()}
    if files is None:
        files = {'node_modules/@deepseek-ai/dsh/lib/bin.js': b'bin', 'runtime/ohos/preload.mjs': b'preload',
                 'runtime/ohos/.manifest.json': b'{}', 'runtime/ohos/\u4e2d\u6587/client.node.js': b'javascript'}
    payload.update(files)
    files = {name: data for name, data in payload.items() if name not in omit}
    manifest = {'schema': 1, 'runtimeVersion': 'archive-audit-fixture', 'dshVersion': '0.2.1-rc.4',
                'nodeVersion': '24.22.1', 'files': [
                    {'path': name, 'size': len(data), 'sha256': hashlib.sha256(data).hexdigest()}
                    for name, data in sorted(files.items())]}
    if change_manifest:
        change_manifest(manifest)
    return pack([member('manifest.json', json.dumps(manifest, ensure_ascii=False).encode(), 0)] +
                [member('files/' + name, data, 8) for name, data in sorted(files.items())] + list(extra))


def deflate(data):
    stream = zlib.compressobj(9, zlib.DEFLATED, -15)
    return stream.compress(data) + stream.flush()


def raw_pack(items):
    """Preserve deliberately inconsistent compressed bytes instead of fixing them."""
    chunks, central, offset = [], [], 0
    for name, declared, method, packed in items:
        name = name.encode('utf-8')
        packed = declared if method == 0 and packed is None else deflate(declared) if packed is None else packed
        flags = 0 if name.isascii() else 0x800
        crc = zlib.crc32(declared)
        local = struct.pack('<I5H3I2H', 0x04034b50, 20, flags, method, 0, 23585,
                            crc, len(packed), len(declared), len(name), 0)
        header = struct.pack('<I6H3I5H2I', 0x02014b50, 0x314, 20, flags, method, 0, 23585,
                             crc, len(packed), len(declared), len(name), 0, 0, 0, 0, 0o100644 << 16, offset)
        chunks.extend([local, name, packed]); central.extend([header, name])
        offset += len(local) + len(name) + len(packed)
    directory = b''.join(central)
    footer = struct.pack('<I4H2IH', 0x06054b50, 0, 0, len(items), len(items), len(directory), offset, 0)
    return b''.join(chunks) + directory + footer


def stream_fixture(declared, packed):
    value = inner({'zz-stream.txt': declared})
    with zipfile.ZipFile(io.BytesIO(value)) as archive:
        items = [(entry.filename, archive.read(entry), entry.compress_type,
                  packed if entry.filename == 'files/zz-stream.txt' else None) for entry in archive.infolist()]
    return raw_pack(items)


class AuditTests(unittest.TestCase):
    def run_audit(self, archived, *, source=None, hap_method=0, extra_hap=(), extra_source=()):
        source = archived if source is None else source
        transmission = pack([member(AUDIT.ASSET, source, 0)] + list(extra_source))
        hap = pack([member(AUDIT.HAP_ASSET, archived, hap_method)] + list(extra_hap))
        with tempfile.TemporaryDirectory(prefix='runtime-archive-audit-') as directory:
            input_path = Path(directory) / 'runtime.zip'
            input_path.write_bytes(transmission)
            with zipfile.ZipFile(io.BytesIO(hap)) as package:
                return AUDIT.audit_runtime(package, input_path)

    def rejected(self, archived, **options):
        report, problems = self.run_audit(archived, **options)
        self.assertTrue(problems)
        self.assertEqual(report, {})

    def test_exact_nested_archive_and_every_content(self):
        data = inner()
        report, problems = self.run_audit(data)
        self.assertEqual(problems, [])
        self.assertEqual(report['files'], len(AUDIT.required_entries()) + 2)
        self.assertEqual(report['dotfiles'], 1)
        self.assertTrue(report['stored'])
        self.assertEqual(report['archiveSHA256'], hashlib.sha256(data).hexdigest())

    def test_outer_archive_must_be_stored(self):
        self.rejected(inner(), hap_method=8)

    def test_no_loose_manifest_can_coexist(self):
        self.rejected(inner(), extra_hap=[member('resources/rawfile/dsh-runtime/manifest.json', b'{}', 0)])

    def test_input_archive_has_exactly_one_member(self):
        self.rejected(inner(), extra_source=[member('other.txt', b'other', 0)])

    def test_packaged_bytes_match_input(self):
        self.rejected(inner(), source=inner(change_manifest=lambda value: value.update(runtimeVersion='different')))

    def test_elf_even_with_valid_hash_and_crc(self):
        self.rejected(inner({'hidden.js': b'\x7fELFreal'}))

    def test_native_suffix(self):
        for name in ['x.node', 'x.so', 'x.SO.1.2']:
            with self.subTest(name=name):
                self.rejected(inner({name: b'non-native text'}))

    def test_parent_escape(self):
        self.rejected(inner({'../escape.js': b'escape'}))

    def test_duplicate_member(self):
        self.rejected(inner(extra=[member('files/runtime/ohos/preload.mjs', b'preload', 8)]))

    def test_unlisted_member(self):
        self.rejected(inner(extra=[member('files/extra.js', b'extra', 8)]))

    def test_file_directory_collision(self):
        self.rejected(inner({'file': b'a', 'file/nested': b'b'}))

    def test_file_sha(self):
        self.rejected(inner(change_manifest=lambda value: value['files'][0].update(sha256='0'*64)))

    def test_file_size(self):
        self.rejected(inner(change_manifest=lambda value: value['files'][0].update(size=100)))

    def test_zip_encryption_metadata(self):
        data = bytearray(inner())
        start = data.index(b'PK\x01\x02')
        struct.pack_into('<H', data, start+8, 1)
        self.rejected(bytes(data))

    def test_symlink_mode(self):
        data = bytearray(inner())
        start = data.index(b'PK\x01\x02')
        struct.pack_into('<I', data, start+38, 0o120777 << 16)
        self.rejected(bytes(data))

    def test_local_crc_mismatch(self):
        data = bytearray(inner())
        struct.pack_into('<I', data, 14, 0)
        self.rejected(bytes(data))

    def test_archive_comment(self):
        data = bytearray(inner())
        struct.pack_into('<H', data, len(data)-2, 1)
        self.rejected(bytes(data))

    def test_corrupt_deflate_is_reported_not_unhandled(self):
        data = bytearray(inner())
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            info = archive.infolist()[1]
        name_size, extras = struct.unpack_from('<HH', data, info.header_offset+26)
        data[info.header_offset+30+name_size+extras] = 0xff
        self.rejected(bytes(data))

    def test_complete_deflate_rejects_trailer_and_concatenated_stream(self):
        for trailer in [b'UNEXPECTED_TRAILER', deflate(b''), deflate(b'more')]:
            with self.subTest(trailer=trailer):
                report, problems = self.run_audit(stream_fixture(b'x', deflate(b'x') + trailer))
                self.assertEqual(report, {})
                self.assertRegex(problems[0], 'trailing|unconsumed')

    def test_expanded_size_is_bounded_before_hidden_megabyte_is_produced(self):
        create = zlib.decompressobj
        observations = []
        class ObservedStream:
            def __init__(self, *args): self.stream = create(*args)
            def __getattr__(self, name): return getattr(self.stream, name)
            def decompress(self, data, maximum):
                output = self.stream.decompress(data, maximum)
                observations.append({'maxOutput': maximum, 'actualOutput': len(output)})
                return output
        data = stream_fixture(b'x', deflate(b'x' * (1024 * 1024)))
        with patch.object(AUDIT.zlib, 'decompressobj', ObservedStream):
            report, problems = self.run_audit(data)
        self.assertEqual(report, {})
        self.assertIn('exceeds manifest size', problems[0])
        self.assertEqual(observations[-1], {'maxOutput': 2, 'actualOutput': 2})
        self.assertTrue(all(0 < value['maxOutput'] <= AUDIT.CHUNK for value in observations))

    def test_empty_and_large_real_streams_remain_valid(self):
        for payload in [b'', b'x', bytes(range(256)) * 4096]:
            with self.subTest(size=len(payload)):
                report, problems = self.run_audit(stream_fixture(payload, deflate(payload)))
                self.assertEqual(problems, [])
                self.assertGreaterEqual(report['bytes'], len(payload))

    def test_truncated_stream_and_declared_size_too_large_fail(self):
        for payload in [b'', b'x', bytes(range(256)) * 64]:
            with self.subTest(size=len(payload)):
                self.rejected(stream_fixture(payload, deflate(payload)[:-1]))
        report, problems = self.run_audit(stream_fixture(b'xx', deflate(b'x')))
        self.assertEqual(report, {})
        self.assertIn('size/CRC/SHA256', problems[0])

    def test_boolean_schema_and_non_json_constants_are_rejected(self):
        for value in [True, False, '1', [], {}]:
            with self.subTest(schema=value):
                self.rejected(inner(change_manifest=lambda manifest: manifest.update(schema=value)))
        self.rejected(inner(change_manifest=lambda manifest: manifest.update(unused=float('nan'))))
        self.rejected(inner(change_manifest=lambda manifest: manifest.update(unused=float('inf'))))

    def test_numeric_one_float_sizes_and_empty_dsh_version_match_core(self):
        def valid(manifest):
            manifest.update(schema=1.0, dshVersion='')
            for item in manifest['files']: item['size'] = float(item['size'])
        report, problems = self.run_audit(inner({'empty.txt': b''}, change_manifest=valid))
        self.assertEqual(problems, [])
        self.assertTrue(report['identicalToInput'])

    def test_each_host_core_required_entry_must_be_present(self):
        for name in AUDIT.required_entries():
            with self.subTest(path=name):
                report, problems = self.run_audit(inner(omit=(name,)))
                self.assertEqual(report, {})
                self.assertIn('Host/Core required runtime entry', problems[0])

    def test_host_core_requirement_disagreement_fails_closed(self):
        host_path = Path('app/ohos/entry/src/main/cpp/host_core.cpp')
        core_path = Path('app/ohos/entry/src/main/ets/runtime/RuntimeCore.ets')
        with tempfile.TemporaryDirectory(prefix='archive-required-contract-') as directory:
            root = Path(directory)
            for relative in [host_path, core_path]:
                (root / relative).parent.mkdir(parents=True, exist_ok=True)
                (root / relative).write_bytes((ROOT / relative).read_bytes())
            self.assertEqual(AUDIT.required_entries(root), AUDIT.required_entries())
            source = (root / core_path).read_text()
            name = AUDIT.required_entries()[0]
            (root / core_path).write_text(source.replace("'" + name + "'", "'other-entry.js'"))
            with self.assertRaisesRegex(ValueError, 'Host::Start and RuntimeCore'):
                AUDIT.required_entries(root)

    def test_full_central_version_needed_field_is_checked(self):
        data = bytearray(inner())
        start = data.index(b'PK\x01\x02')
        struct.pack_into('<H', data, start + 6, 20 + 256)
        self.rejected(bytes(data))

    def test_outer_stored_lengths_cannot_hide_extra_raw_bytes(self):
        payload = inner()
        for which in ['source', 'hap']:
            with self.subTest(which=which), tempfile.TemporaryDirectory(prefix='archive-outer-length-') as directory:
                source = raw_pack([(AUDIT.ASSET, payload, 0, payload + (b'x' if which == 'source' else b''))])
                hap = raw_pack([(AUDIT.HAP_ASSET, payload, 0, payload + (b'x' if which == 'hap' else b''))])
                source_path = Path(directory) / 'input.zip'; source_path.write_bytes(source)
                with zipfile.ZipFile(io.BytesIO(hap)) as archive:
                    report, problems = AUDIT.audit_runtime(archive, source_path)
                self.assertEqual(report, {})
                self.assertTrue(problems)


def old_fragment_probe(before, output):
    """Execute only the exact old runtime-audit block, not fake a whole HAP run."""
    text = before.read_text()
    start = text.index('    # The runtime: RuntimeInstaller')
    end = text.index("    report['problems'] = problems", start)
    fragment = '\n'.join(line[4:] if line.startswith('    ') else line for line in text[start:end].splitlines())
    ast.parse(fragment)
    data = inner()
    transmission = pack([member(AUDIT.ASSET, data, 0)])
    hap = pack([member(AUDIT.HAP_ASSET, data, 0)])
    with tempfile.TemporaryDirectory(prefix='archive-old-audit-') as directory:
        source = Path(directory) / 'runtime.zip'
        source.write_bytes(transmission)
        with zipfile.ZipFile(io.BytesIO(hap)) as zipped:
            namespace = {'args': SimpleNamespace(runtime=source), 'zipfile': zipfile, 'json': json,
                         'zipped': zipped, 'entries': {info.filename: info for info in zipped.infolist()},
                         'read': zipped.read, 'RAWFILE': 'resources/rawfile/', 'problems': [], 'report': {},
                         'sha256': lambda value: hashlib.sha256(value).hexdigest()}
            try:
                exec(compile(fragment, str(before)+':runtime-block', 'exec'), namespace)
                observation = {'oldAccepted': True}
            except Exception as error:
                observation = {'oldAccepted': False, 'type': type(error).__name__, 'error': str(error)}
            report, problems = AUDIT.audit_runtime(zipped, source)
    observation.update(beforeSource=str(before), beforeSHA256=hashlib.sha256(before.read_bytes()).hexdigest(),
                       fragmentSHA256=hashlib.sha256(fragment.encode()).hexdigest(), afterProblems=problems,
                       after=report, scope='exact old runtime-audit fragment only; no full native/resources HAP audit claim')
    output.write_text(json.dumps(observation, ensure_ascii=False, indent=2)+'\n')
    if observation['oldAccepted'] or problems:
        raise AssertionError('old-fail/new-pass evidence missing')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--before', type=Path)
    parser.add_argument('--report', type=Path)
    args, rest = parser.parse_known_args()
    if args.before:
        old_fragment_probe(args.before, args.report)
    unittest.main(argv=[__file__, *rest])
