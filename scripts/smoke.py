#!/usr/bin/env python3
"""Read-only hardware probes and isolated authenticated daemon smoke test."""
import json, os, pathlib, signal, subprocess, sys, tempfile, time, urllib.request, urllib.error

binary = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '.build/debug/display-cli').resolve()
with tempfile.TemporaryDirectory(prefix='display-cli-smoke-') as directory:
    env = dict(os.environ, DISPLAYDJ_HOME=directory)
    def cli(*args, expected=0):
        result = subprocess.run([str(binary), *args, '--json'], env=env, capture_output=True, text=True, timeout=30)
        assert result.returncode == expected, (args, result.returncode, result.stderr, result.stdout)
        return json.loads(result.stdout)
    assert cli('version')['data']['version'] == '0.3.0'
    legacy = subprocess.run([str(binary.with_name('displaydj')), '--version'], capture_output=True, text=True, timeout=10)
    assert legacy.returncode == 0 and legacy.stdout.strip() == '0.3.0'
    assert cli('help')['ok']
    assert not cli('disconnect', expected=2)['ok']
    assert not cli('unknown-command', expected=2)['ok']
    assert not cli('serve', '--host', '0.0.0.0', expected=2)['ok']
    assert not cli('serve', '--port', '65536', expected=2)['ok']
    assert not cli('serve', '--port', '-1', expected=2)['ok']
    assert cli('displays')['ok']
    assert cli('doctor')['data']['ddcEngine'].startswith('DisplayDJCore')
    for args in [
        ('volume', 'set', '50%'),
        ('contrast', 'set', 'restore', '--display', 'external'),
        ('volume', 'set', '50%', '--dispaly', 'external'),
        ('brightness', 'set', '50%', '--dry-run'),
        ('disconnect', '--display', 'main', '--dry-run'),
        ('modes', 'set', 'bogus', '--display', 'main'),
        ('modes', 'list', '--dry-run'),
        ('profile', 'save', '../bad'),
        ('profile', 'apply', 'work', '--dry-run=false'),
        ('modes', 'list', '--display'),
        ('modes', 'list', '--display', 'main', '--display', 'all'),
        ('brightness', 'set', '50%', '--ramp', 'oops'),
    ]:
        assert not cli(*args, expected=2)['ok'], args
    assert cli('profile', 'list')['data']['profiles'] == []
    mode_reports = cli('modes', 'list')['data']['displays']
    if mode_reports:
        report = mode_reports[0]
        preview = cli('modes', 'set', str(report['current']['id']), '--display', 'uuid:' + report['displayUUID'], '--dry-run')['data']
        assert preview['dryRun'] and not preview['verified']
        assert 'hiDPI' in preview['requested']
    # A synthetic offline preset checks persistence and missing-display failure
    # without changing physical brightness, volume or display configuration.
    profile_path = pathlib.Path(directory) / 'profiles.json'
    profile_path.write_text(json.dumps({'version': 1, 'profiles': [{
        'name': 'offline-test', 'savedAt': '2026-09-21T00:00:00Z', 'displays': [{
            'displayUUID': '00000000-0000-0000-0000-000000000001',
            'name': 'Offline fixture', 'brightness': 0.5, 'transport': 'ddc'
        }]
    }]}))
    assert cli('profile', 'show', 'offline-test')['data']['name'] == 'offline-test'
    assert not cli('profile', 'apply', 'offline-test', '--dry-run', expected=3)['ok']
    assert cli('profile', 'delete', 'offline-test')['data']['deleted'] == 'offline-test'
    print('PASS CLI contracts, strict arguments, display modes/dry-run and isolated profiles')
    process = subprocess.Popen([str(binary), 'serve', '--port', '0'], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        descriptor_path = pathlib.Path(directory) / 'daemon.json'
        for _ in range(100):
            if descriptor_path.exists(): break
            if process.poll() is not None:
                raise AssertionError(process.stderr.read().decode())
            time.sleep(0.1)
        descriptor = json.loads(descriptor_path.read_text())
        token = (pathlib.Path(directory) / 'token').read_text().strip()
        base = f'http://127.0.0.1:{descriptor["port"]}'
        try:
            urllib.request.urlopen(base + '/v1/health', timeout=5)
            raise AssertionError('unauthenticated request accepted')
        except urllib.error.HTTPError as error:
            assert error.code == 401, error.code
        def request(path):
            req = urllib.request.Request(base + path, headers={'Authorization': 'Bearer ' + token})
            with urllib.request.urlopen(req, timeout=30) as response:
                return json.load(response)
        health = request('/v1/health')
        assert health['ok'] and health['data']['activeSessions'] == 0
        assert request('/v1/displays')['ok']
        assert request('/v1/agent/sessions')['ok']
        assert request('/v1/modes')['ok']
        assert request('/v1/profiles')['data']['profiles'] == []
        assert cli('modes', 'list')['ok']
        assert cli('profile', 'list')['data']['profiles'] == []
        routes = request('/v1')['data']['routes']
        assert 'POST /v1/controls/:control' in routes and 'POST /v1/profiles/:name/apply' in routes
        assert cli('daemon', 'status')['ok']
        print('PASS isolated daemon startup, token authentication, health, display and session routes')
    finally:
        process.send_signal(signal.SIGTERM)
        try: process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait(); raise AssertionError('daemon shutdown stalled')
        process.stderr.close()
    assert process.returncode == 0, process.returncode
    assert not descriptor_path.exists(), 'daemon descriptor survived clean shutdown'
    print('PASS daemon clean shutdown (no hardware mutation requested)')
