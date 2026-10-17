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
from pathlib import Path

TOKEN = 'integration-token'
controls = []
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
        if not self.path.startswith('/api/v1/ws?token='):
            self.reply(404, {})
            return
        key = self.headers['Sec-WebSocket-Key']
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        self.send_response(101)
        self.send_header('Upgrade', 'websocket')
        self.send_header('Connection', 'Upgrade')
        self.send_header('Sec-WebSocket-Accept', accept)
        self.end_headers()
        if not self.path.endswith('token=' + TOKEN):
            self.frame(struct.pack('!H', 1008), 8)
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
    executable = root / 'build/Pear Now Playing.app/Contents/MacOS/PearNowPlaying'
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        env = dict(os.environ, PEAR_TEST_PORT=str(server.server_port))
        result = subprocess.run([str(executable), '--integration-test'], env=env, timeout=20)
        raise SystemExit(result.returncode)
    finally:
        server.shutdown()
        server.server_close()
