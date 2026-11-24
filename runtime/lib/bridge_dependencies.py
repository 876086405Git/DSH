#!/usr/bin/env python3
"""Stage the bridge's locked, already installed PDF text-extraction dependency.

This does not download or install packages. Call npm ci --ignore-scripts
--omit=optional with the bridge package-lock.json before staging.
"""
import argparse
import json
from pathlib import Path
import shutil


BRIDGE = Path(__file__).resolve().parents[1] / 'bridge/dsh-go-bridge'
PDF_FILES = {'package.json', 'README.md', 'LICENSE',
             'legacy/build/pdf.min.mjs', 'legacy/build/pdf.worker.min.mjs'}


def pdf_files(prefix):
    """Return the exact local extraction subset, retaining its licenses."""
    if (prefix / 'package-lock.json').read_bytes() != (BRIDGE / 'package-lock.json').read_bytes():
        raise ValueError('Bridge dependency lock differs; rerun its standard npm ci preparation')
    root = prefix / 'node_modules/pdfjs-dist'
    package = json.loads((root / 'package.json').read_text())
    if package.get('name') != 'pdfjs-dist' or package.get('version') != '6.5.438':
        raise ValueError('Expected installed pdfjs-dist 6.5.438')
    selected = []
    for path in sorted(root.rglob('*')):
        relative = path.relative_to(root)
        if relative.as_posix() not in PDF_FILES and relative.parts[0] not in ('cmaps', 'standard_fonts'):
            continue
        if path.is_symlink():
            raise ValueError('PDF extraction dependency must contain regular files')
        if path.is_file():
            selected.append(path)
    if len(selected) != 190 or not PDF_FILES.issubset(path.relative_to(root).as_posix() for path in selected):
        raise ValueError('The installed PDF extraction resources are incomplete')
    return root, selected


def copy_pdf(prefix, node_modules):
    root, selected = pdf_files(prefix)
    target = node_modules / 'pdfjs-dist'
    for source in selected:
        output = target / source.relative_to(root)
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, output)
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    pdf_files(args.prefix)
    shutil.copytree(BRIDGE, args.out, symlinks=True, ignore=shutil.ignore_patterns('node_modules'))
    copy_pdf(args.prefix, args.out / 'node_modules')


if __name__ == '__main__':
    main()
