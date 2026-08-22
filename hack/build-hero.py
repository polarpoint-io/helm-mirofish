#!/usr/bin/env python3
"""Generate static/hero.png.

The palette is sampled from upstream MiroFish-Offline's own banner
(static/image/mirofish-offline-banner.png in nikmcfly/MiroFish-Offline) so
the two repos read as one family: near-black ground, copper accent, white
condensed-mono wordmark over a copper rule, "> " stat lines along the foot.
The mark reworks upstream's oval mirror -- node graph over a shoal -- as a
seven-handled helm wheel, for Helm and for Kubernetes' seven-sided mark.

Rendering is deterministic: the shoal and graph come from a seeded RNG, so
re-running this reproduces the same image byte for byte.

Usage:
    make hero        # fetches the font, renders, quantises to static/hero.png
"""
import base64
import math
import pathlib
import random
import subprocess
import sys
import urllib.request

ROOT   = pathlib.Path(__file__).resolve().parent.parent
OUT    = ROOT / "static" / "hero.png"
WORK   = ROOT / ".hero-build"
FONTS  = WORK / "fonts"
FONT_BASE = "https://github.com/JetBrains/JetBrainsMono/raw/master/fonts/ttf"
FONT_FILES = ["JetBrainsMono-ExtraBold.ttf", "JetBrainsMono-Medium.ttf",
              "JetBrainsMono-Regular.ttf"]


def fetch_fonts():
    FONTS.mkdir(parents=True, exist_ok=True)
    for name in FONT_FILES:
        dest = FONTS / name
        if dest.exists():
            continue
        print("fetching", name)
        urllib.request.urlretrieve(f"{FONT_BASE}/{name}", dest)


def b64(name):
    return base64.b64encode((FONTS / name).read_bytes()).decode()

# ---- palette lifted from upstream's banner ---------------------------------
BG_A      = "#0a0e0f"   # sampled background
BG_B      = "#0d1113"
COPPER_LT = "#f0b58d"
COPPER    = "#e67847"
COPPER_MD = "#cc7f5b"   # the rule under upstream's wordmark
COPPER_DK = "#a04c28"
COPPER_XD = "#5c2a16"
MUTED     = "#8f9498"
GREY_FISH = "#6d7477"

W, H = 2400, 1260
CX, CY, R = 560, 560, 300          # the mark
TX = 1030                          # wordmark left edge

fetch_fonts()

# Seeded so the image is reproducible across runs.
rnd = random.Random(7)

# ---- node graph inside the disc --------------------------------------------
nodes, edges = [], []
for i in range(9):
    a = rnd.uniform(0, math.tau)
    d = R * 0.72 * math.sqrt(rnd.uniform(0.02, 1.0))
    nodes.append((CX + d * math.cos(a), CY + d * math.sin(a) * 0.98))
for i, p in enumerate(nodes):
    order = sorted(range(len(nodes)), key=lambda j: (nodes[j][0]-p[0])**2 + (nodes[j][1]-p[1])**2)
    for j in order[1:3]:
        if (min(i, j), max(i, j)) not in edges:
            edges.append((min(i, j), max(i, j)))

graph = []
for i, j in edges:
    x1, y1 = nodes[i]; x2, y2 = nodes[j]
    graph.append(f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" '
                 f'stroke="url(#edge)" stroke-width="2.6" opacity=".7"/>')
for x, y in nodes:
    rr = rnd.uniform(7, 13)
    graph.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{rr:.1f}" fill="{COPPER_DK}" opacity=".9"/>')
    graph.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="{rr*0.45:.1f}" fill="{COPPER_LT}" opacity=".85"/>')

# ---- the shoal -------------------------------------------------------------
shoal = []
for row in range(7):
    for col in range(6):
        # stagger alternate rows so the shoal reads as a school, not a grid
        x = CX - R*0.70 + col * (R*0.265) + (R*0.13 if row % 2 else 0) + rnd.uniform(-16, 16)
        y = CY - R*0.64 + row * (R*0.205) + rnd.uniform(-11, 11)
        if (x-CX)**2/(R*0.79)**2 + (y-CY)**2/(R*0.79)**2 > 1:
            continue
        sc = rnd.uniform(0.80, 1.16)
        # the shoal drifts toward the upper right, like upstream's
        rot = rnd.uniform(-16, 10) - (y - CY) / R * 8
        lead = rnd.random() < 0.55
        fill = COPPER if lead else GREY_FISH
        op = rnd.uniform(0.85, 1.0) if lead else rnd.uniform(0.38, 0.58)
        shoal.append(f'<use href="#fish" x="0" y="0" fill="{fill}" opacity="{op:.2f}" '
                     f'transform="translate({x:.1f},{y:.1f}) rotate({rot:.1f}) scale({sc:.2f})"/>')

# ---- helm-wheel handles (7 -- the Kubernetes count) ------------------------
handles = []
for k in range(7):
    a = -math.pi/2 + k * math.tau/7
    x1 = CX + math.cos(a) * (R*0.995)
    y1 = CY + math.sin(a) * (R*0.995)
    x2 = CX + math.cos(a) * (R*1.20)
    y2 = CY + math.sin(a) * (R*1.20)
    handles.append(
        f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" '
        f'stroke="url(#rim)" stroke-width="20" stroke-linecap="round"/>'
        f'<circle cx="{x2:.1f}" cy="{y2:.1f}" r="17" fill="url(#knob)"/>')

# ---- spokes inside the rim -------------------------------------------------
spokes = []
for k in range(7):
    a = -math.pi/2 + k * math.tau/7
    x1 = CX + math.cos(a) * (R*0.66)
    y1 = CY + math.sin(a) * (R*0.66)
    x2 = CX + math.cos(a) * (R*0.90)
    y2 = CY + math.sin(a) * (R*0.90)
    spokes.append(f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" '
                  f'stroke="{COPPER_XD}" stroke-width="7" opacity=".28" stroke-linecap="round"/>')

html = f'''<!doctype html>
<meta charset="utf-8">
<style>
  @font-face {{ font-family:"JBM"; font-weight:800;
    src:url(data:font/ttf;base64,{b64("JetBrainsMono-ExtraBold.ttf")}) format("truetype"); }}
  @font-face {{ font-family:"JBM"; font-weight:500;
    src:url(data:font/ttf;base64,{b64("JetBrainsMono-Medium.ttf")}) format("truetype"); }}
  @font-face {{ font-family:"JBM"; font-weight:400;
    src:url(data:font/ttf;base64,{b64("JetBrainsMono-Regular.ttf")}) format("truetype"); }}
  html,body {{ margin:0; padding:0; background:{BG_A}; }}
  svg {{ display:block; }}
</style>
<svg width="{W}" height="{H}" viewBox="0 0 {W} {H}" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{BG_B}"/><stop offset="1" stop-color="{BG_A}"/>
    </linearGradient>
    <radialGradient id="glow" cx="24%" cy="42%" r="52%">
      <stop offset="0" stop-color="{COPPER}" stop-opacity=".13"/>
      <stop offset="1" stop-color="{COPPER}" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="rim" x1="0" y1="0" x2="0.7" y2="1">
      <stop offset="0"   stop-color="{COPPER_LT}"/>
      <stop offset=".42" stop-color="{COPPER}"/>
      <stop offset=".78" stop-color="{COPPER_DK}"/>
      <stop offset="1"   stop-color="{COPPER_XD}"/>
    </linearGradient>
    <radialGradient id="knob" cx="35%" cy="30%" r="75%">
      <stop offset="0" stop-color="{COPPER_LT}"/><stop offset="1" stop-color="{COPPER_DK}"/>
    </radialGradient>
    <radialGradient id="disc" cx="34%" cy="26%" r="86%">
      <stop offset="0" stop-color="#1b2124"/><stop offset="1" stop-color="#080b0c"/>
    </radialGradient>
    <linearGradient id="edge" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{COPPER_LT}"/><stop offset="1" stop-color="{COPPER_DK}"/>
    </linearGradient>
    <linearGradient id="sheen" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0"   stop-color="#ffffff" stop-opacity=".10"/>
      <stop offset=".45" stop-color="#ffffff" stop-opacity="0"/>
    </linearGradient>
    <clipPath id="discClip"><circle cx="{CX}" cy="{CY}" r="{R*0.855:.1f}"/></clipPath>

    <!-- one fish, reused across the shoal -->
    <g id="fish">
      <path d="M -26,0 C -20,-9 -6,-13 6,-11 C 17,-9 24,-3 28,0
               C 24,3 17,9 6,11 C -6,13 -20,9 -26,0 Z"/>
      <path d="M -26,0 L -41,-11 L -36,0 L -41,11 Z"/>
      <circle cx="19" cy="-2.6" r="2.4" fill="#0a0e0f" opacity=".75"/>
    </g>
  </defs>

  <rect width="{W}" height="{H}" fill="url(#bg)"/>
  <rect width="{W}" height="{H}" fill="url(#glow)"/>

  <!-- ============================ the mark ============================ -->
  <g>
    {''.join(handles)}
    <circle cx="{CX}" cy="{CY}" r="{R*0.945:.1f}" fill="none" stroke="url(#rim)" stroke-width="{R*0.115:.1f}"/>
    <circle cx="{CX}" cy="{CY}" r="{R*1.002:.1f}" fill="none" stroke="{COPPER_LT}" stroke-width="2" opacity=".35"/>
    <circle cx="{CX}" cy="{CY}" r="{R*0.888:.1f}" fill="none" stroke="{COPPER_XD}" stroke-width="2" opacity=".8"/>
    <circle cx="{CX}" cy="{CY}" r="{R*0.855:.1f}" fill="url(#disc)"/>
    <g clip-path="url(#discClip)">
      {''.join(spokes)}
      {''.join(graph)}
      {''.join(shoal)}
      <rect x="{CX-R}" y="{CY-R}" width="{2*R}" height="{2*R}" fill="url(#sheen)"/>
    </g>
  </g>

  <!-- ============================ wordmark ============================ -->
  <text x="{TX}" y="566" font-family="JBM" font-weight="800" font-size="140"
        letter-spacing="9" fill="#ffffff">HELM MIROFISH</text>
  <rect x="{TX}" y="620" width="1174" height="5" fill="{COPPER_MD}"/>
  <text x="{TX}" y="698" font-family="JBM" font-weight="500" font-size="46"
        letter-spacing="2.5" fill="{COPPER_MD}">MiroFish-Offline on Kubernetes</text>

  <!-- ============================ footer ============================== -->
  <g font-family="JBM" font-weight="400" font-size="41" fill="{MUTED}">
    <text x="86" y="1075">&gt; 1 chart, 4 workloads</text>
    <text x="86" y="1131">&gt; 0 cloud APIs</text>
    <text x="86" y="1187">&gt; ollama local or remote</text>
    <text x="{W-86}" y="1187" text-anchor="end" fill="{COPPER_MD}" opacity=".85">polarpoint-io/helm-mirofish</text>
  </g>
</svg>'''

WORK.mkdir(parents=True, exist_ok=True)
page = WORK / "hero.html"
page.write_text(html)

shot = WORK / "shot.js"
shot.write_text(f"""
const {{ chromium }} = require('playwright');
(async () => {{
  const b = await chromium.launch();
  const p = await b.newPage({{ viewport: {{ width: {W}, height: {H} }}, deviceScaleFactor: 1 }});
  await p.goto('file://{page}');
  await p.waitForTimeout(700);
  await p.screenshot({{ path: '{WORK / "hero-raw.png"}' }});
  await b.close();
}})();
""")

try:
    subprocess.run(["node", str(shot)], check=True, cwd=WORK)
except (subprocess.CalledProcessError, FileNotFoundError):
    sys.exit("rendering needs node with playwright installed: npm i -g playwright && npx playwright install chromium")

from PIL import Image  # noqa: E402  (only needed once the render succeeded)

raw = Image.open(WORK / "hero-raw.png").convert("RGB")
# Flat gradients and text: a 256-colour palette cuts the file by ~3x with no
# visible banding, which matters for something every README view downloads.
raw.convert("P", palette=Image.ADAPTIVE, colors=256,
            dither=Image.FLOYDSTEINBERG).save(OUT, optimize=True)
print(f"wrote {OUT} ({OUT.stat().st_size // 1024} KB, {raw.size[0]}x{raw.size[1]})")
