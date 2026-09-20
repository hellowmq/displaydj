#!/usr/bin/env python3
"""Opt-in single-display brightness write/readback/restore check; never disconnects."""
import argparse
import json
import math
import os
import pathlib
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--display', required=True, help='Exact uuid: selector of an explicitly authorized display')
parser.add_argument('--bin-dir', default='.build/debug')
parser.add_argument('--allow-write', action='store_true', help='Authorize a 3 percentage point adjustment and restoration')
args = parser.parse_args()
if not args.allow_write or not args.display.startswith('uuid:'):
    parser.error('An exact UUID and --allow-write are required')
bin_dir = pathlib.Path(args.bin_dir).resolve()
state = pathlib.Path(tempfile.mkdtemp(prefix='displaydj-hardware-'))
env = {k: v for k, v in os.environ.items() if not k.startswith('DISPLAYDJ_')}
env['DISPLAYDJ_HOME'] = str(state)

def run(binary, *arguments):
    completed = subprocess.run([str(bin_dir / binary), *arguments, '--json'],
                               env=env, capture_output=True, text=True, timeout=20)
    payload = json.loads(completed.stdout)
    if completed.returncode or not payload.get('ok'):
        raise RuntimeError(f'{binary} {arguments[0]} failed with exit {completed.returncode}')
    return payload

def read():
    result = run('displaydj', 'get', 'brightness', '--display', args.display)
    if result.get('backend') != 'apple-silicon-ddc':
        raise RuntimeError('Hardware DDC read required')
    return result['value']

baseline = read()
if not math.isfinite(baseline) or not 0 <= baseline <= 100:
    raise RuntimeError('Invalid baseline; refusing write')
rows = run('display-cli', 'displays')['data']['displays']
targets = [d for d in rows if 'uuid:' + d['uuid'].lower() == args.display.lower()]
if len(targets) != 1 or targets[0]['capability']['preferred'] != 'ddc':
    raise RuntimeError('Main CLI must resolve exactly one hardware DDC target')
target = baseline - 3 if baseline >= 5 else baseline + 3
# Keep this local recovery record even on failure; do not include identity in public reports.
recovery = state / 'hardware-recovery.json'
recovery.write_text(json.dumps({'selector': args.display, 'baselinePercent': baseline}))
recovery.chmod(0o600)
print(f'Baseline {baseline:g}%; target {target:g}%; recovery directory: {state}', flush=True)
try:
    results = run('display-cli', 'brightness', 'set', f'{target:.12g}%', '--display', args.display)['data']['results']
    if len(results) != 1 or not results[0]['ok'] or results[0]['transport'] != 'ddc':
        raise RuntimeError('Unverified hardware write')
    observed = read()
    if abs(observed - target) > 1:
        raise RuntimeError(f'Readback mismatch: requested {target:g}, got {observed:g}')
    print(f'PASS hardware write and independent readback: {observed:g}%', flush=True)
finally:
    # The isolated state contains only this one target's recovery snapshot.
    restored = run('display-cli', 'brightness', 'restore')['data']['results']
    if len(restored) != 1 or not restored[0]['ok'] or restored[0]['transport'] != 'ddc':
        raise RuntimeError(f'Restoration unverified; retained recovery directory: {state}')
    final = read()
    if abs(final - baseline) > 0.01:
        raise RuntimeError(f'Restoration mismatch ({final:g}% vs {baseline:g}%); recovery: {state}')
    print(f'PASS original hardware brightness restored and independently read: {final:g}%', flush=True)
