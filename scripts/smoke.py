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
    assert cli('version')['data']['version'] == '0.2.2'
    legacy = subprocess.run([str(binary.with_name('displaydj')), '--version'], capture_output=True, text=True, timeout=10)
    assert legacy.returncode == 0 and legacy.stdout.strip() == '0.2.2'
    assert cli('help')['ok']
    assert not cli('disconnect', expected=2)['ok']
    assert not cli('unknown-command', expected=2)['ok']
    assert not cli('serve', '--host', '0.0.0.0', expected=2)['ok']
    assert not cli('serve', '--port', '65536', expected=2)['ok']
    assert not cli('serve', '--port', '-1', expected=2)['ok']
    assert cli('displays')['ok']
    assert cli('doctor')['data']['ddcEngine'].startswith('DisplayDJCore')
    print('PASS CLI version, help, error contracts, display discovery and capabilities')
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
