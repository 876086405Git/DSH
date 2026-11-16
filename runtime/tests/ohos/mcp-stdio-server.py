#!/usr/bin/env python3
"""A real, local stdio MCP server used only by the explicit host guest fixture."""
import json
import os
from pathlib import Path
import sys


trace = (Path(sys.argv[1]) / ('server-' + str(os.getpid()) + '.jsonl')).open('x', buffering=1)
sequence = 0


def record(event, **fields):
    global sequence
    sequence += 1
    trace.write(json.dumps({'seq': sequence, 'pid': os.getpid(), 'event': event, **fields},
                           ensure_ascii=False) + '\n')


record('started')
for raw in sys.stdin.buffer:
    request = json.loads(raw)
    method = request['method']
    record('request', message=request)
    if 'id' not in request:
        if method != 'notifications/initialized':
            raise ValueError('unexpected notification: ' + method)
        continue
    reply = {'jsonrpc': '2.0', 'id': request['id']}
    if method == 'server/discover':
        reply['error'] = {'code': -32601, 'message': 'explicit legacy stdio fixture'}
    elif method == 'initialize':
        reply['result'] = {'protocolVersion': request['params']['protocolVersion'],
                           'capabilities': {'tools': {}},
                           'serverInfo': {'name': 'host-stdio-fixture', 'version': '1'}}
    elif method == 'tools/list':
        reply['result'] = {'tools': [{'name': 'echo', 'description': 'Echo explicit fixture text',
            'inputSchema': {'type': 'object', 'properties': {'text': {'type': 'string'}},
                            'required': ['text'], 'additionalProperties': False}}]}
    elif method == 'tools/call':
        assert request['params']['name'] == 'echo'
        text = request['params']['arguments']['text']
        assert isinstance(text, str)
        reply['result'] = {'content': [{'type': 'text', 'text': text}], 'isError': False}
    else:
        raise ValueError('unexpected method: ' + method)
    wire = json.dumps(reply, ensure_ascii=False, separators=(',', ':')) + '\n'
    sys.stdout.buffer.write(wire.encode('utf-8'))
    sys.stdout.buffer.flush()
    record('response', message=reply)
record('stdin-eof')
trace.close()
