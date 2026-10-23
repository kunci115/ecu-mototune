"""Offline review of the watch screens: renders the RideView layout with the device profile's real
font sizes (simulator.json) so overlaps show up before a sideload. Mirrors RideView.layout().
usage: python3 garmin/tools/mock_screens.py <out dir> [device id]
"""
import json, math, os, sys
from PIL import Image, ImageDraw, ImageFont

DEV = sys.argv[2] if len(sys.argv) > 2 else "fr265"
PROF = os.path.expanduser(f"~/Library/Application Support/Garmin/ConnectIQ/Devices/{DEV}/simulator.json")
j = json.load(open(PROF))
W, H = j["display"]["location"]["width"], j["display"]["location"]["height"]
PPI = j["ppi"]
FONT_PT = {f["name"]: f["size"] for f in j["fonts"][0]["fonts"] if "size" in f}
FONT_FILE = "/System/Library/Fonts/Supplemental/Arial.ttf"   # Roboto-like metrics
def px(name): return int(round(FONT_PT[name] * PPI / 72))
def font(name): return ImageFont.truetype(FONT_FILE, px(name))
def fh(name): return int(round(px(name) * 1.17))              # ≈ dc.getFontHeight
# button angles from key rectangle centres vs screen centre
loc = j["display"]["location"]; cx0, cy0 = loc["x"] + W/2, loc["y"] + H/2
ANG = {}
for k in j["keys"]:
    r = k["location"]; kx, ky = r["x"] + r["width"]/2, r["y"] + r["height"]/2
    ANG[k["id"]] = math.degrees(math.atan2(-(ky - cy0), kx - cx0)) % 360

ACCENT, GOOD, WARN, BAD, TEXT, DIM, FAINT = "#25E0D0", "#34D399", "#FBBF24", "#F87171", "#EDF1F5", "#8A93A0", "#3A424D"

# ---- layout() mirror ----
hx, hm = fh("xtiny"), fh("large")
gap = int(H * 0.01); yHeader = int(H * 0.07); yLabel = yHeader + hx + gap; yBig = yLabel + hx; yBottom = int(H * 0.87)
bigFont = "numberMild"
for f in ["numberThaiHot", "numberHot", "numberMedium", "numberMild"]:
    if yBig + fh(f) + gap + hm + hx <= yBottom - gap: bigFont = f; break
yPair = yBig + fh(bigFont) + gap; yPairLabel = yPair + hm - hx // 4
print(f"{DEV}: {W}x{H} xtiny={px('xtiny')}px mild={px('numberMild')}px big={bigFont} ({px(bigFont)}px) "
      f"yHeader={yHeader} yLabel={yLabel} yBig={yBig} yPair={yPair} yPairLabel={yPairLabel} yBottom={yBottom} angles={ {k: round(v) for k, v in ANG.items()} }")

def canvas():
    im = Image.new("RGB", (W, H), "black"); return im, ImageDraw.Draw(im)
def round_mask(im):
    m = Image.new("L", (W, H), 0); ImageDraw.Draw(m).ellipse([0, 0, W - 1, H - 1], fill=255)
    out = Image.new("RGB", (W, H), "#202020"); out.paste(im, mask=m); return out
def text(d, x, y, s, name, color, anchor="ma"):   # Garmin draws from the top-left of the line box
    d.text((x, y), s, font=font(name), fill=color, anchor=anchor)
def label(d, x, y, s, color): text(d, x, y, s, "xtiny", color)
def arc(d, a0, a1, color, width, inset):          # clockwise from a0 to a1 (math degrees, ccw positive)
    r = W / 2; box = [inset, inset, W - inset, H - inset]
    # PIL arcs go clockwise in screen coords from start to end, measured clockwise from 3 o'clock
    s0, s1 = (-a0) % 360, (-a1) % 360
    d.arc(box, s0, s1, fill=color, width=width)
def gauge(d, frac, color, red):
    arc(d, 225, -45, FAINT, 8, 6)
    if red is not None: arc(d, 225 - int(270 * red), -45, "#5A2A2A", 8, 6)
    f = max(0, min(1, frac))
    if f > 0.01: arc(d, 225, 225 - int(270 * f), color, 8, 6)
def hint(d, ang, word, color):
    arc(d, ang + 11, ang - 11, color, 6, 4)
    if not word: return
    r = W / 2; rad = math.radians(ang); x = r + (r - 34) * math.cos(rad); y = r - (r - 34) * math.sin(rad)
    text(d, x, y - hx / 2, word, "xtiny", color, anchor="la" if 90 < ang < 270 else "ra")
def big(d, caption, ccolor, s, color):
    label(d, W / 2, yLabel, caption, ccolor); text(d, W / 2, yBig, s, bigFont, color)
def pair(d, lv, ll, rv, rl, color):
    text(d, W * 0.28, yPair, lv, "large", color); text(d, W * 0.72, yPair, rv, "large", color)
    label(d, W * 0.28, yPairLabel, ll, DIM); label(d, W * 0.72, yPairLabel, rl, DIM)
    d.line([W / 2, yPair + gap * 2, W / 2, yPairLabel + gap * 2], fill=FAINT)
def header(d, t="REC 0:49"):
    d.ellipse([W/2 - 44, yHeader + hx/2 - 4, W/2 - 36, yHeader + hx/2 + 4], fill=BAD)
    text(d, W/2 - 30, yHeader, t, "xtiny", TEXT, anchor="la")
    hint(d, ANG["enter"], None, FAINT); hint(d, ANG["up"], None, ACCENT)
def dots(d, page):
    x = W / 2 - 3 * 7
    for i in range(4):
        r = 4 if i == page else 3; c = ACCENT if i == page else FAINT
        d.ellipse([x + i*14 - r, yBottom + hx/2 - r, x + i*14 + r, yBottom + hx/2 + r], fill=c)
def footer(d, msg, color):
    d.rectangle([0, yBottom - 2, W, yBottom + hx + 2], fill="black"); label(d, W/2, yBottom, msg, color)

out = sys.argv[1]; os.makedirs(out, exist_ok=True)
# checklist
im, d = canvas()
icon = Image.open(os.path.join(os.path.dirname(__file__), "../MotoTuneRide/resources/drawables/launcher_icon_60.png")).convert("RGBA")
im.paste(icon, (W//2 - 30, yHeader), icon)
label(d, W/2, yHeader + 60 + gap, "M O T O T U N E", ACCENT)
rowH = hx + gap * 2; y = H // 2 - rowH * 2
for i, (lab, val, ok) in enumerate([("PHONE", "ok", True), ("ECU", "—", False), ("GPS", "wait", False), ("HEART", "78", True)]):
    d.ellipse([W*0.27 - 5, y + rowH/2 - 5, W*0.27 + 5, y + rowH/2 + 5], fill=GOOD if ok else FAINT)
    text(d, W*0.32, y + gap, lab, "xtiny", TEXT, anchor="la"); text(d, W*0.73, y + gap, val, "xtiny", TEXT if ok else DIM, anchor="ra")
    if i < 3: d.line([W*0.26, y + rowH, W*0.74, y + rowH], fill=FAINT)
    y += rowH
label(d, W/2, y + gap, "gps: q2 · 1s ago", FAINT)
hint(d, ANG["enter"], None, FAINT); hint(d, ANG["esc"], None, FAINT)
label(d, W/2, yBottom, "waiting for ECU", DIM)
round_mask(im).save(f"{out}/1-checklist.png")
# engine
im, d = canvas(); gauge(d, 7800/12000, ACCENT, 0.83); big(d, "R P M", DIM, "7800", TEXT); pair(d, "3", "GEAR", "64", "TPS %", TEXT); header(d); dots(d, 0)
round_mask(im).save(f"{out}/2-engine.png")
# mixture, stale + footer
im, d = canvas(); gauge(d, (12.8-10)/6, GOOD, 0.6); big(d, "A F R", DIM, "12.8", GOOD); pair(d, "12.5", "TARGET", "2.46", "BPW ms", TEXT); header(d, "REC 12:34"); footer(d, "waiting for ECU", DIM)
round_mask(im).save(f"{out}/3-mixture.png")
# dyno
im, d = canvas(); gauge(d, 0.023, GOOD, None); big(d, "P U L L S", DIM, "5", TEXT); pair(d, "+2.3%", "REAL", "3", "MARKS", GOOD); header(d); dots(d, 2)
round_mask(im).save(f"{out}/4-dyno.png")
# ride
im, d = canvas(); gauge(d, 78/160, ACCENT, None); big(d, "K M / H  ·  E C U", DIM, "78", TEXT); pair(d, "92", "BPM", "12:34", "TIME", TEXT); header(d); dots(d, 3)
round_mask(im).save(f"{out}/5-ride.png")
# paused
im, d = canvas(); hmild = fh("numberMild"); label(d, W/2, yLabel, "P A U S E D", WARN); text(d, W/2, H/2 - hmild/2, "12:34", "numberMild", TEXT); label(d, W/2, yBottom, "3 marks · max 9850", DIM)
hint(d, ANG["enter"], "resume", ACCENT); hint(d, ANG["up"], "save", GOOD); hint(d, ANG["esc"], "menu", DIM)
round_mask(im).save(f"{out}/6-paused.png")
# contact sheet
files = sorted(f for f in os.listdir(out) if f[0].isdigit())
sheet = Image.new("RGB", (W * len(files), H), "#202020")
for i, f in enumerate(files): sheet.paste(Image.open(f"{out}/{f}"), (W * i, 0))
sheet.save(f"{out}/sheet.png"); print("wrote", out)
