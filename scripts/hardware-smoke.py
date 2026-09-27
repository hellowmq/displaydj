#!/usr/bin/env python3
"""Two-stage single-display DDC check with a private command log; never disconnects."""
import argparse
import atexit
import datetime
import json
import math
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--display', required=True, help='Exact uuid: selector of an explicitly authorized display')
parser.add_argument('--control', choices=('brightness', 'contrast', 'volume'), default='brightness')
parser.add_argument('--bin-dir', default='.build/debug')
stage = parser.add_mutually_exclusive_group(required=True)
stage.add_argument('--preflight', action='store_true', help='Read-only identification and selected control baseline')
stage.add_argument('--allow-write', action='store_true', help='Authorize a 3 percentage point adjustment and restoration')
args = parser.parse_args()
if not re.fullmatch(r'uuid:[0-9a-fA-F-]{36}', args.display):
    parser.error('An exact uuid:<UUID> selector is required')
bin_dir = pathlib.Path(args.bin_dir).resolve()
state = pathlib.Path(tempfile.mkdtemp(prefix='displaydj-hardware-'))
log_path = state / 'commands.jsonl'
report_path = state / 'report.json'
env = {k: v for k, v in os.environ.items() if not k.startswith('DISPLAYDJ_')}
env['DISPLAYDJ_HOME'] = str(state)
report = {'stage': 'preflight' if args.preflight else 'write', 'control': args.control,
          'selector': args.display, 'status': 'running', 'logPath': str(log_path),
          'baselinePercent': None, 'targetPercent': None, 'writeReadbackPercent': None,
          'restoredPercent': None, 'error': None}

def save_report():
    fd = os.open(report_path, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as stream:
        json.dump(report, stream, ensure_ascii=False, indent=2)
        stream.write('\n')

def record_failure(error_type, error, traceback):
    report['status'] = 'failed'
    report['error'] = str(error)
    sys.__excepthook__(error_type, error, traceback)

atexit.register(save_report)
sys.excepthook = record_failure

def log(event):
    event['timeUTC'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    with log_path.open('a', encoding='utf-8') as stream:
        stream.write(json.dumps(event, ensure_ascii=False) + '\n')
    log_path.chmod(0o600)

def run(binary, *arguments):
    command = [str(bin_dir / binary), *arguments, '--json']
    started = time.monotonic()
    try:
        completed = subprocess.run(command, env=env, capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired as error:
        log({'command': command, 'timeoutSeconds': 30, 'stdout': str(error.stdout or ''),
             'stderr': str(error.stderr or '')})
        raise RuntimeError(f'{binary} {arguments[0]} timed out; diagnostic log: {log_path}') from error
    log({'command': command, 'exitCode': completed.returncode,
         'durationSeconds': round(time.monotonic() - started, 3),
         'stdout': completed.stdout, 'stderr': completed.stderr})
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(f'{binary} {arguments[0]} did not return JSON; diagnostic log: {log_path}') from error
    if completed.returncode or not payload.get('ok'):
        raise RuntimeError(f'{binary} {arguments[0]} failed with exit {completed.returncode}; diagnostic log: {log_path}')
    return payload

def read():
    if args.control == 'brightness':
        result = run('displaydj', 'get', 'brightness', '--display', args.display)
        if result.get('backend') != 'apple-silicon-ddc':
            raise RuntimeError('Hardware DDC read required')
        return result['value']
    results = run('display-cli', args.control, 'get', '--display', args.display)['data']['results']
    if len(results) != 1 or not results[0]['ok'] or results[0]['value'] is None:
        raise RuntimeError(f'{args.control} baseline unavailable; diagnostic log: {log_path}')
    return results[0]['value'] * 100

print(f'Stage: {"read-only preflight" if args.preflight else "authorized write"}; private log: {log_path}; report: {report_path}', flush=True)
run('display-cli', 'doctor')
baseline = read()
if not math.isfinite(baseline) or not 0 <= baseline <= 100:
    raise RuntimeError('Invalid baseline; refusing write')
report['baselinePercent'] = baseline
rows = run('display-cli', 'displays')['data']['displays']
targets = [d for d in rows if 'uuid:' + d['uuid'].lower() == args.display.lower()]
if len(targets) != 1 or targets[0]['capability']['preferred'] != 'ddc':
    raise RuntimeError('Main CLI must resolve exactly one hardware DDC target')
if args.preflight:
    report['status'] = 'passed'
    print(f'PASS read-only DDC {args.control} baseline: {baseline:g}%; no write requested', flush=True)
    raise SystemExit(0)
target = baseline - 3 if baseline >= 5 else baseline + 3
report['targetPercent'] = target
# Keep this local recovery record even on failure; do not include identity in public reports.
recovery = state / 'hardware-recovery.json'
fd = os.open(recovery, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
with os.fdopen(fd, 'w', encoding='utf-8') as stream:
    json.dump({'selector': args.display, 'control': args.control,
               'baselinePercent': baseline}, stream)
print(f'Baseline {baseline:g}%; target {target:g}%; recovery directory: {state}', flush=True)
try:
    results = run('display-cli', args.control, 'set', f'{target:.12g}%', '--display', args.display)['data']['results']
    if len(results) != 1 or not results[0]['ok'] or (
        args.control == 'brightness' and results[0]['transport'] != 'ddc'
    ):
        raise RuntimeError('Unverified hardware write')
    observed = read()
    report['writeReadbackPercent'] = observed
    if abs(observed - target) > 1:
        raise RuntimeError(f'Readback mismatch: requested {target:g}, got {observed:g}')
    print(f'PASS hardware write and independent readback: {observed:g}%', flush=True)
finally:
    # The isolated state contains only this one target's recovery snapshot.
    if args.control == 'brightness':
        restored = run('display-cli', 'brightness', 'restore')['data']['results']
    else:
        restored = run('display-cli', args.control, 'set', f'{baseline:.12g}%',
                       '--display', args.display)['data']['results']
    if len(restored) != 1 or not restored[0]['ok'] or (
        args.control == 'brightness' and restored[0]['transport'] != 'ddc'
    ):
        raise RuntimeError(f'Restoration unverified; retained recovery directory: {state}')
    final = read()
    report['restoredPercent'] = final
    if abs(final - baseline) > 0.01:
        raise RuntimeError(f'Restoration mismatch ({final:g}% vs {baseline:g}%); recovery: {state}')
    print(f'PASS original hardware {args.control} restored and independently read: {final:g}%', flush=True)
    report['status'] = 'passed'
