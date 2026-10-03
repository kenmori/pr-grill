#!/usr/bin/env python3
"""Build the pr-grill demo from demo/script.<lang>.json.

  python3 demo/build.py en        -> demo/pr-grill.en.svg  (animated; embeds in the README)
  python3 demo/build.py en --video -> demo/pr-grill.en.webm and .mp4 (Chromium via Playwright + ffmpeg)

Timing is derived from the script: typed input at ~22 chars/s, output lines every 0.35 s,
a pause after each scene. The SVG loops three times; the video plays once.
"""
import html
import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
W, H = 880, 520
LINE_H = 22
PAD_X, PAD_Y = 24, 46
FONT = "ui-monospace, SFMono-Regular, Menlo, Consolas, 'Noto Sans Mono CJK JP', monospace"
COLORS = {
    "": "#d4d4d4", "dim": "#8a8f98", "head": "#79c0ff", "warn": "#ffa657", "ok": "#7ee787",
    "ask": "#f2cc60", "q": "#ffffff", "meter": "#56d4dd", "title": "#ffffff", "prompt": "#7ee787",
}
TYPE_S = 1 / 22      # seconds per typed character
OUT_S = 0.35         # seconds per output line
STEP_S = 0.9         # seconds per progress line (lines starting with "Step ")
PAUSE_IN = 0.5       # after the user hits enter
PAUSE_SCENE = 2.4    # hold at the end of a scene
PAUSE_CARD = 4.0
LOOPS = 3


def layout(script):
    """Turn the script into timed frames: [(t_start, t_end, line_index, segments)]."""
    frames, t = [], 0.6
    for scene in script["scenes"]:
        start, rows = t, []
        if "card" in scene:
            for i, segs in enumerate(scene["card"]):
                rows.append((t, i + 4, segs))
                t += 0.25
            t += PAUSE_CARD
        else:
            li = 0
            for ev in scene["events"]:
                if "in" in ev:
                    text = ev["in"]
                    # progressive typing: one frame per character, each replacing the previous
                    for k in range(1, len(text) + 1):
                        rows.append((t, li, [("> ", "prompt"), (text[:k], "q")], t + TYPE_S))
                        t += TYPE_S
                    rows.append((t, li, [("> ", "prompt"), (text, "q")]))
                    li += 1
                    t += PAUSE_IN
                else:
                    for segs in ev["out"]:
                        rows.append((t, li, segs))
                        li += 1
                        t += STEP_S if segs and segs[0][0].startswith("Step ") else OUT_S
            t += PAUSE_SCENE
        end = t
        for row in rows:
            t0, li, segs = row[0], row[1], row[2]
            t1 = row[3] if len(row) > 3 else end
            frames.append((t0, t1, li, segs))
    return frames, t


def svg(script, frames, total):
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="{FONT}" font-size="14">',
           f'<title>{html.escape(script["title"])}</title>',
           f'<rect width="{W}" height="{H}" rx="10" fill="#0d1117"/>',
           '<circle cx="20" cy="18" r="6" fill="#ff5f57"/><circle cx="40" cy="18" r="6" fill="#febc2e"/><circle cx="60" cy="18" r="6" fill="#28c840"/>',
           f'<text x="{W/2}" y="23" text-anchor="middle" fill="#8a8f98" font-size="12">claude — pr-grill</text>']
    for t0, t1, li, segs in frames:
        y = PAD_Y + li * LINE_H
        begins = ";".join(f"{t0 + k*total:.2f}s" for k in range(LOOPS))
        ends = ";".join(f"{t1 + k*total:.2f}s" for k in range(LOOPS))
        title_attr = ' font-size="26" font-weight="bold"'
        tspans = "".join(f'<tspan fill="{COLORS[c]}"{title_attr if c == "title" else ""}>{html.escape(s)}</tspan>' for s, c in segs)
        out.append(f'<text x="{PAD_X}" y="{y}" opacity="0" xml:space="preserve">{tspans}'
                   f'<set attributeName="opacity" to="1" begin="{begins}"/>'
                   f'<set attributeName="opacity" to="0" begin="{ends}"/></text>')
    out.append("</svg>")
    return "\n".join(out)


def player_html(script, frames, total):
    data = json.dumps([{"t0": t0, "t1": t1, "li": li, "segs": segs} for t0, t1, li, segs in frames])
    return f"""<!doctype html><meta charset="utf-8"><title>{html.escape(script["title"])}</title>
<style>body{{margin:0;background:#000}}#s{{width:{W}px;height:{H}px;background:#0d1117;border-radius:10px;position:relative;margin:0 auto;
font:14px/{LINE_H}px {FONT};color:#d4d4d4}}.l{{position:absolute;left:{PAD_X}px;white-space:pre;opacity:0}}
#bar{{position:absolute;top:10px;width:100%;text-align:center;color:#8a8f98;font-size:12px}}</style>
<div id="s"><div id="bar">claude — pr-grill</div></div>
<script>
const C={json.dumps(COLORS)},F={data},s=document.getElementById('s'),t0=performance.now();
const els=F.map(f=>{{const d=document.createElement('div');d.className='l';d.style.top=({PAD_Y}-16+f.li*{LINE_H})+'px';
  f.segs.forEach(([x,c])=>{{const sp=document.createElement('span');sp.style.color=C[c];if(c==='title'){{sp.style.fontSize='26px';sp.style.fontWeight='bold'}}sp.textContent=x;d.appendChild(sp)}});s.appendChild(d);return d}});
function tick(){{const t=(performance.now()-t0)/1000;F.forEach((f,i)=>{{els[i].style.opacity=(t>=f.t0&&t<f.t1)?1:0}});
  if(t<{total:.2f}+0.5)requestAnimationFrame(tick);else document.title='done'}}requestAnimationFrame(tick);
</script>"""


def record(lang, total):
    from playwright.sync_api import sync_playwright
    page_path = HERE / f"player.{lang}.html"
    vdir = HERE / "_video"
    vdir.mkdir(exist_ok=True)
    with sync_playwright() as p:
        # A pinned Playwright may not match the preinstalled browser; CHROMIUM_PATH overrides the executable
        exe = os.environ.get("CHROMIUM_PATH")
        b = p.chromium.launch(executable_path=exe) if exe else p.chromium.launch()
        ctx = b.new_context(viewport={"width": W, "height": H}, record_video_dir=str(vdir),
                            record_video_size={"width": W, "height": H})
        page = ctx.new_page()
        page.goto(page_path.as_uri())
        page.wait_for_function("document.title === 'done'", timeout=int((total + 10) * 1000))
        video = page.video.path()
        ctx.close(); b.close()
    webm = HERE / f"pr-grill.{lang}.webm"
    os.replace(video, webm)
    mp4 = HERE / f"pr-grill.{lang}.mp4"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(webm), "-c:v", "libx264", "-pix_fmt", "yuv420p",
                    "-movflags", "+faststart", str(mp4)], check=True)
    return webm, mp4


def main():
    lang = sys.argv[1] if len(sys.argv) > 1 else "en"
    script = json.loads((HERE / f"script.{lang}.json").read_text(encoding="utf-8"))
    frames, total = layout(script)
    (HERE / f"pr-grill.{lang}.svg").write_text(svg(script, frames, total), encoding="utf-8")
    (HERE / f"player.{lang}.html").write_text(player_html(script, frames, total), encoding="utf-8")
    print(f"{lang}: {len(frames)} frames, {total:.1f}s  -> pr-grill.{lang}.svg")
    if "--video" in sys.argv:
        webm, mp4 = record(lang, total)
        print(f"video -> {webm.name}, {mp4.name}")


if __name__ == "__main__":
    main()
