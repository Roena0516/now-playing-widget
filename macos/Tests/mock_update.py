#!/usr/bin/env python3
"""Update test with a local stand-in for GitHub's releases API. Never connects to external services.

Builds a "9.9.9" copy of the built app (re-signed ad hoc), puts it in a DMG served as the latest release, and runs
the app's --update-test against a scratch copy of the app (never the installed one). Also checks that a wrong
SHA-256, a DMG holding another version, and an up-to-date app are handled.
"""
import hashlib
import json
import plistlib
import shutil
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILT = ROOT / 'build/Now Playing Widget.app'
EXE = BUILT / 'Contents/MacOS/NowPlayingWidget'
release = {}
files = {}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path.endswith('/releases/latest'):
            data = json.dumps(release).encode()
        elif self.path.startswith('/dl/') and self.path[4:] in files:
            data = files[self.path[4:]]
        else:
            self.send_response(404); self.end_headers(); return
        self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def version_of(app):
    with open(app / 'Contents/Info.plist', 'rb') as f:
        return plistlib.load(f)['CFBundleShortVersionString']


def make_dmg(work, version, name):
    """A DMG holding the built app relabelled as `version`."""
    stage = work / f'stage-{version}'
    app = stage / 'Now Playing Widget.app'
    shutil.rmtree(stage, ignore_errors=True)
    subprocess.run(['ditto', str(BUILT), str(app)], check=True)
    plist = app / 'Contents/Info.plist'
    info = plistlib.loads(plist.read_bytes())
    info['CFBundleShortVersionString'] = info['CFBundleVersion'] = version
    plist.write_bytes(plistlib.dumps(info))
    subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True, capture_output=True)
    dmg = work / name
    subprocess.run(['hdiutil', 'create', '-quiet', '-volname', 'Now Playing Widget', '-srcfolder', str(stage),
                    '-format', 'UDZO', '-ov', str(dmg)], check=True)
    return dmg.read_bytes()


def run_update(port, target):
    result = subprocess.run([str(EXE), '--update-test', f'http://127.0.0.1:{port}/releases/latest', str(target)],
                            capture_output=True, text=True, timeout=120)
    return result.returncode, result.stdout.strip()


def main():
    work = Path(tempfile.mkdtemp(prefix='pnp-update-'))
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_port
    try:
        installed = work / 'Applications/Pear Now Playing.app'
        installed.parent.mkdir()
        subprocess.run(['ditto', str(BUILT), str(installed)], check=True)
        current = version_of(installed)

        def offer(version, data, digest=None, prefix='NowPlayingWidget'):
            name = f'{prefix}-macOS-{version}.dmg'
            files[name] = data
            release.clear()
            release.update({'tag_name': f'v{version}', 'html_url': f'http://127.0.0.1:{port}/page', 'assets': [
                {'name': f'{prefix}-Windows-{version}.zip', 'browser_download_url': 'x', 'digest': 'sha256:00'},
                {'name': name, 'browser_download_url': f'http://127.0.0.1:{port}/dl/{name}',
                 'digest': 'sha256:' + (digest or hashlib.sha256(data).hexdigest())}]})

        new = make_dmg(work, '9.9.9', 'new.dmg')

        offer('9.9.9', new, digest='0' * 64)
        code, out = run_update(port, installed)
        assert code != 0 and 'SHA-256' in out and version_of(installed) == current, f'tampered download must be refused: {out}'

        offer('9.9.9', make_dmg(work, '9.9.8', 'other.dmg'))
        code, out = run_update(port, installed)
        assert code != 0 and version_of(installed) == current, f'a DMG with another version must be refused: {out}'

        # installed under the old name (up to 1.9.4): updated and renamed to Now Playing Widget.app
        offer('9.9.9', new)
        code, out = run_update(port, installed)
        assert code == 0 and out == 'UPDATED to 9.9.9 at Now Playing Widget.app', out
        renamed = installed.parent / 'Now Playing Widget.app'
        assert version_of(renamed) == '9.9.9'
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(renamed)], check=True)
        leftovers = [p.name for p in renamed.parent.iterdir() if p.name != renamed.name]
        assert not leftovers, f'old app left behind: {leftovers}'

        code, out = run_update(port, renamed)
        assert code == 0 and out == 'UP TO DATE', out

        # a release with only the old file names is still taken (and the app keeps its new name)
        offer('9.9.10', make_dmg(work, '9.9.10', 'legacy.dmg'), prefix='PearNowPlaying')
        code, out = run_update(port, renamed)
        assert code == 0 and out == 'UPDATED to 9.9.10 at Now Playing Widget.app' and version_of(renamed) == '9.9.10', out
        print('PASS: update from GitHub releases (download, SHA-256, DMG check, swap, rename from Pear Now Playing.app, old file names), wrong digest and wrong version refused, up to date')
    finally:
        server.shutdown()
        shutil.rmtree(work, ignore_errors=True)


if __name__ == '__main__':
    try:
        main()
    except AssertionError as e:
        print(f'Update test failed: {e}', file=sys.stderr)
        raise SystemExit(1)
