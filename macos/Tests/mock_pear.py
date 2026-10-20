#!/usr/bin/env python3
"""Dependency-free Pear API fixture. Never connects to external services."""
import base64
import hashlib
import json
import os
import struct
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit
from pathlib import Path

TOKEN = 'integration-token'
controls = []
auth_requests = []
# Pear 3.11 checks a bearer header on the WebSocket upgrade (and answers 401); 3.12 accepts the upgrade and
# reads the `token` query parameter, closing with 1008 when it is missing. The app must work with both.
MODE = '3.12'
class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *_):
        pass
    def reply(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', '0')))
        if self.path == '/auth/pear-now-playing-macos':
            auth_requests.append(self.path)
            self.reply(200, {'accessToken': TOKEN})
        elif self.path in ['/api/v1/next', '/api/v1/previous', '/api/v1/toggle-play']:
            if self.headers.get('Authorization') != 'Bearer ' + TOKEN:
                self.reply(401, {})
                return
            controls.append(self.path.rsplit('/', 1)[1])
            self.reply(200, {})
        else:
            self.reply(404, {})
    def frame(self, payload, opcode=1):
        length = len(payload)
        head = bytes([0x80 | opcode])
        head += bytes([length]) if length < 126 else b'\x7e' + struct.pack('!H', length)
        self.wfile.write(head + payload)
        self.wfile.flush()
    def do_GET(self):
        if self.path == '/test-controls':
            self.reply(200, controls)
            return
        if self.path == '/test-auth':
            self.reply(200, {'count': len(auth_requests)})
            return
        if self.path == '/api/v1/queue/next':
            if self.headers.get('Authorization') != 'Bearer ' + TOKEN:
                self.reply(401, {})
                return
            self.reply(200, {'title': '다음 곡', 'videoId': 'next-track01', 'shortBylineText': {'runs': [{'text': '다음 가수'}]}, 'lengthText': {'runs': [{'text': '3:05'}]}})
            return
        url = urlsplit(self.path)
        if url.path != '/api/v1/ws':
            self.reply(404, {})
            return
        if MODE == '3.11' and self.headers.get('Authorization') != 'Bearer ' + TOKEN:
            self.reply(401, {'message': 'Unauthorized'})
            return
        query_token = parse_qs(url.query).get('token', [''])[0]
        key = self.headers['Sec-WebSocket-Key']
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        self.send_response(101)
        self.send_header('Upgrade', 'websocket')
        self.send_header('Connection', 'Upgrade')
        self.send_header('Sec-WebSocket-Accept', accept)
        self.end_headers()
        if MODE == '3.12' and query_token != TOKEN:
            self.frame(struct.pack('!H', 1008) + b'Unauthorized', 8)
            self.close_connection = True
            return
        messages = [
            {'type': 'PLAYER_INFO', 'song': {'title': '모의 서버 日本語', 'videoId': 'integration-track', 'songDuration': 200, 'elapsedSeconds': 5, 'isPaused': False}},
            {'type': 'POSITION_CHANGED', 'position': 42},
            {'type': 'PLAYER_STATE_CHANGED', 'isPlaying': False, 'position': 42},
        ]
        for message in messages:
            self.frame(json.dumps(message).encode())
        time.sleep(15)
        self.close_connection = True

if __name__ == '__main__':
    root = Path(__file__).resolve().parents[1]
    executable = root / 'build/Now Playing Widget.app/Contents/MacOS/NowPlayingWidget'
    for MODE in ['3.12', '3.11']:
        controls.clear()
        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            print(f'Pear {MODE}-style WebSocket authorization:', flush=True)
            env = dict(os.environ, PEAR_TEST_PORT=str(server.server_port))
            result = subprocess.run([str(executable), '--integration-test'], env=env, timeout=20)
            if result.returncode != 0:
                raise SystemExit(result.returncode)
        finally:
            server.shutdown()
            server.server_close()
