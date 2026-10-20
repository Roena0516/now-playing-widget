#!/usr/bin/env python3
"""A fake Discord IPC socket for the Discord presence (DiscordPresence.swift): checks the handshake, the activity
sent for a song, that a near-identical update isn't sent again, the rate gap, and the clearing at the end."""
import json, os, socket, struct, subprocess, sys, tempfile, threading, time

APP = os.path.join(os.path.dirname(__file__), "..", "build", "Pear Now Playing.app", "Contents", "MacOS", "PearNowPlaying")
folder = tempfile.mkdtemp(prefix="discord-")
path = os.path.join(folder, "discord-ipc-0")
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path); server.listen(1); server.settimeout(15)
frames = []

def read_exactly(conn, n):
    data = b""
    while len(data) < n:
        chunk = conn.recv(n - len(data))
        if not chunk: return None
        data += chunk
    return data

def serve():
    conn, _ = server.accept()
    while True:
        header = read_exactly(conn, 8)
        if header is None: break
        op, length = struct.unpack("<II", header)
        body = json.loads(read_exactly(conn, length))
        frames.append((op, body, time.time()))
        if op == 0:
            reply = json.dumps({"cmd": "DISPATCH", "evt": "READY", "data": {"v": 1}}).encode()
        else:
            reply = json.dumps({"cmd": body["cmd"], "nonce": body.get("nonce"), "data": {}, "evt": None}).encode()
        conn.sendall(struct.pack("<II", 1, len(reply)) + reply)

threading.Thread(target=serve, daemon=True).start()
run = subprocess.run([APP, "--discord-test", folder], timeout=30)
time.sleep(0.2)

def fail(message):
    print("FAIL:", message); print(json.dumps([(op, body) for op, body, _ in frames], ensure_ascii=False, indent=1)[:3000]); sys.exit(1)

if run.returncode != 0: fail("app exited with %d" % run.returncode)
if not frames or frames[0][0] != 0 or frames[0][1] != {"v": 1, "client_id": "1562020013953515553"}: fail("handshake")
sets = [(body, at) for op, body, at in frames[1:] if op == 1 and body.get("cmd") == "SET_ACTIVITY"]
if len(sets) != 3: fail("expected 3 updates (song, seek, clear), got %d" % len(sets))
song = sets[0][0]["args"]["activity"]
if sets[0][0]["args"]["pid"] <= 0: fail("pid")
if song["type"] != 2 or song["details"] != "アイドル - Idol" or song["state"] != "YOASOBI": fail("song fields")
if song["timestamps"] != {"start": 1800000000000, "end": 1800000226000}: fail("timestamps")
if song["assets"]["large_image"] != "https://i.ytimg.com/vi/ZRtdQ81jPUQ/hq720.jpg": fail("cover")
if song.get("details_url") != "https://music.youtube.com/watch?v=ZRtdQ81jPUQ" or song["assets"].get("large_url") != song["details_url"]: fail("title link to YouTube Music")
if song["buttons"] != [{"label": "Now Playing Widget", "url": "https://github.com/Roena0516/pear-now-playing"}]: fail("button")
seek = sets[1][0]["args"]["activity"]
if seek["timestamps"]["start"] != 1799999940000 or "buttons" in seek: fail("seek / button off")
if sets[1][1] - sets[0][1] < 3.9: fail("updates closer than Discord's rate allows")
if sets[2][0]["args"]["activity"] is not None: fail("clearing")
print("PASS: Discord handshake, listening activity (song, link, cover, progress, button), no resend for drift, rate gap, clearing")
