#!/usr/bin/env python3
"""Prints the UDID of an iPhone simulator on the newest iOS runtime."""
import json
import subprocess
import sys

devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))['devices']
for runtime in sorted((name for name in devices if 'iOS' in name), reverse=True):
    for device in devices[runtime]:
        if device['name'].startswith('iPhone'):
            print(device['udid'])
            sys.exit(0)
sys.exit('No iPhone simulator is available')
