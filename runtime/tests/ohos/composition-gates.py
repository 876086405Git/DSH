#!/usr/bin/env python3
"""Real-file failure probes for the rawfile composition boundary."""
import argparse
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    args.out = args.out.absolute()
    args.out.mkdir(parents=True, exist_ok=False)
    repo = Path(__file__).resolve().parents[3]
    spec = importlib.util.spec_from_file_location('composition', repo / 'runtime/ohos/package/compose-runtime.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    source = args.out / 'source'
    source.mkdir()
    rows = []
    for name, data, accepted in [('client.node.js', b'export const client = true;\n', True),
                                  ('native.node', b'ordinary fixture', False),
                                  ('libmodule.so.1.2', b'ordinary fixture', False),
                                  ('hidden.dat', b'\x7fELFnot-a-rawfile', False),
                                  ('hidden-wasm.dat', b'\0asmnot-a-rawfile', False)]:
        file = source / name
        file.write_bytes(data)
        composer = module.Composer(args.out / ('payload-' + name))
        try:
            composer.add(file, source, 'fixture', name)
            assert accepted
            assert composer.payload[name]['sha256'] == module.digest(data)
        except ValueError:
            assert not accepted
            assert composer.payload == {}
        rows.append({'case': name, 'accepted': accepted, 'status': 'PASS'})
    existing = args.out / 'existing'
    existing.mkdir()
    sentinel = existing / 'keep'
    sentinel.write_bytes(b'preserve-existing-output')
    try:
        module.assemble(SimpleNamespace(target='ohos', dsh_prefix=source, process_prefix=source, out=existing))
        raise AssertionError('existing output was accepted')
    except ValueError as error:
        assert str(error) == 'Output already exists; preserved'
    assert sentinel.read_bytes() == b'preserve-existing-output'
    rows.append({'case': 'existing-output-preserved', 'status': 'PASS'})
    (args.out / 'report.json').write_text(json.dumps(rows, indent=2) + '\n')
    print(json.dumps({'passed': len(rows)}))


if __name__ == '__main__':
    main()
