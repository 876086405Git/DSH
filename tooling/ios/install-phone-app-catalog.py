#!/usr/bin/env python3
"""Upload a local app-name inventory to an installed, signed PhoneRunner helper."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile


def run(arguments):
    result = subprocess.run(['xcrun', 'devicectl', *arguments], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError('devicectl failed (exit %d); check the device connection and Xcode setup' % result.returncode)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--runner-bundle-id', required=True)
    parser.add_argument('--output', required=True, type=Path, help='Private local JSON output path')
    args = parser.parse_args()
    output = args.output.expanduser().resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.phone-apps-', dir=output.parent) as temporary:
        inventory = Path(temporary) / 'inventory.json'
        run(['device', 'info', 'apps', '--device', args.device, '--include-all-apps', '--json-output', str(inventory)])
        apps = json.loads(inventory.read_text())['result']['apps']
        catalog = []
        for app in apps:
            identifier, name = app.get('bundleIdentifier'), app.get('name')
            if (isinstance(identifier, str) and isinstance(name, str) and 0 < len(name) <= 256
                    and re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', identifier)):
                catalog.append({'id': identifier, 'name': name})
        encoded = (json.dumps(catalog, ensure_ascii=False) + '\n').encode()
        if not catalog or len(encoded) > 1024 * 1024:
            raise RuntimeError('Unexpected device app inventory')
        stage = Path(temporary) / 'catalog.json'
        stage.write_bytes(encoded)
        stage.chmod(0o600)
        stage.replace(output)
    run(['device', 'copy', 'to', '--device', args.device, '--domain-type', 'appDataContainer',
         '--domain-identifier', args.runner_bundle_id, '--source', str(output),
         '--destination', 'Documents/dsh-app-catalog.json'])
    print('Uploaded %d app names; inventory stays on this computer and phone.' % len(catalog))


if __name__ == '__main__':
    main()
