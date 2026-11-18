#!/usr/bin/env python3
"""Generate a build-only header from the single OHOS runtime Node version pin."""
import argparse
import json
import re
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pin', type=Path, default=Path(__file__).resolve().parent.parent / 'node-version.json')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--print-version', action='store_true')
    args = parser.parse_args()
    version = json.loads(args.pin.read_text())
    if not isinstance(version, str) or not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version):
        parser.error('Node version pin must be one canonical major.minor.patch JSON string')
    parts = [int(part) for part in version.split('.')]
    if any(part > 0xffffffff for part in parts):
        parser.error('Node version components must fit uint32')
    if not args.output and not args.print_version:
        parser.error('Provide --output or --print-version')
    if args.output:
        content = ('// Generated from runtime/ohos/node-version.json; do not edit.\n'
                   '#pragma once\n'
                   f'#define DSH_NODE_VERSION_STRING "{version}"\n'
                   f'#define DSH_NODE_VERSION_MAJOR {parts[0]}\n'
                   f'#define DSH_NODE_VERSION_MINOR {parts[1]}\n'
                   f'#define DSH_NODE_VERSION_PATCH {parts[2]}\n')
        args.output.parent.mkdir(parents=True, exist_ok=True)
        if not args.output.exists() or args.output.read_text() != content:
            args.output.write_text(content)
    if args.print_version:
        print(version)


if __name__ == '__main__':
    main()
