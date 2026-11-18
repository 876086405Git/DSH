#!/usr/bin/env python3
# python3 crash-notes.py MINUTES: the crash reports macOS wrote in the last MINUTES minutes (the
# simulator's processes are ordinary Mac processes), as annotations: what killed it, and the
# crashed thread's frames. A job log needs a GitHub sign-in to read; annotations don't.
import json
import pathlib
import sys
import time

since = time.time() - float(sys.argv[1]) * 60
folder = pathlib.Path.home() / 'Library/Logs/DiagnosticReports'
reports = sorted(p for p in folder.glob('*.ips') if p.stat().st_mtime >= since) if folder.is_dir() else []
for report in reports[:6]:
    text = report.read_text(errors='replace')
    head, _, body = text.partition('\n')
    try:
        data = json.loads(body)
    except ValueError:
        print(f'::notice title=crash {report.name}::{text[:900]!r}')
        continue
    images = data.get('usedImages', [])
    exception = data.get('exception', {})
    lines = [f"{data.get('procName', '?')} {exception.get('type', '')} {exception.get('signal', '')} "
             f"{exception.get('subtype', '')} {data.get('termination', {}).get('indicator', '')}".strip()]
    for thread in data.get('threads', []):
        if not thread.get('triggered'):
            continue
        for frame in thread.get('frames', [])[:24]:
            index = frame.get('imageIndex')
            image = images[index].get('name', '?') if isinstance(index, int) and index < len(images) else '?'
            symbol = frame.get('symbol', hex(frame.get('imageOffset', 0)))
            where = f" {frame['sourceFile']}:{frame.get('sourceLine', '')}" if 'sourceFile' in frame else ''
            lines.append(f'{image} {symbol}+{frame.get("symbolLocation", 0)}{where}')
    note = ' | '.join(lines).replace('%', '%25')
    print(f'::error title=crash {report.name}::{note[:3500]}')
if not reports:
    print('::notice title=crash reports::none in the last %s minutes' % sys.argv[1])
