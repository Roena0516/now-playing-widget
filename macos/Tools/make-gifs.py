#!/usr/bin/env python3
"""The README's animations (docs/*.gif) from the app's own renderer.

    ./macos/build.sh && python3 macos/Tools/make-gifs.py

Runs the app with --render-demo (PNG frames drawn at 2x, see macos/Sources/DemoRenderer.swift), scales them to
`scale` and writes one looping GIF per scene with a palette shared by all of its frames. Needs Pillow.
"""
import shutil, subprocess, sys, tempfile
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'macos/build/Now Playing Widget.app/Contents/MacOS/NowPlayingWidget'
SCENES = {'hero': 'lyrics-scroll.gif', 'marquee': 'title-marquee.gif', 'pause': 'pause-resume.gif'}
FPS = 20
SCALE = 1.5   # of the 1x layout: crisp on high-density screens, small enough for a README

def main():
    work = Path(tempfile.mkdtemp(prefix='nowplaying-demo-'))
    subprocess.run([str(APP), '--render-demo', str(work)], check=True)
    for scene, name in SCENES.items():
        files = sorted((work / scene).glob('*.png'))
        frames = []
        for f in files:
            im = Image.open(f).convert('RGB')
            w, h = im.size
            frames.append(im.resize((round(w / 2 * SCALE), round(h / 2 * SCALE)), Image.LANCZOS))
        # one palette for the whole scene (taken from a few frames), so colours don't flicker between frames
        sample = Image.new('RGB', (frames[0].width, frames[0].height * 4))
        for k, i in enumerate(range(0, len(frames), max(1, len(frames) // 4))):
            if k < 4: sample.paste(frames[i], (0, frames[0].height * k))
        palette = sample.quantize(colors=255, method=Image.MEDIANCUT)
        quantized = [f.quantize(palette=palette, dither=Image.NONE) for f in frames]
        out = ROOT / 'docs' / name
        quantized[0].save(out, save_all=True, append_images=quantized[1:], duration=round(1000 / FPS), loop=0, optimize=True, disposal=1)
        print(f'{out.relative_to(ROOT)}: {len(frames)} frames, {frames[0].size}, {out.stat().st_size // 1024} KB')
    shutil.rmtree(work, ignore_errors=True)

if __name__ == '__main__':
    sys.exit(main())
