"""MotoTune app icon: an ECU chip with a tachometer heart, linked to sibling ECUs — next-gen ECU control."""
import math, sys
from PIL import Image, ImageDraw, ImageFilter

S = 4                       # supersample
W = 1024 * S
CY = (0x25, 0xE0, 0xD0)     # signature cyan
CY_DIM = (0x18, 0x8F, 0x86)
BG_TOP, BG_BOT = (0x10, 0x17, 0x22), (0x05, 0x07, 0x0B)
WHITE = (0xED, 0xF1, 0xF5)

def lerp(a, b, t): return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

# ---- background: vertical gradient + soft cyan glow behind the chip
img = Image.new("RGB", (W, W), BG_BOT)
px = img.load()
grad = Image.new("RGB", (1, W))
for y in range(W): grad.putpixel((0, y), lerp(BG_TOP, BG_BOT, y / W))
img = grad.resize((W, W))
glow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
g = ImageDraw.Draw(glow)
g.ellipse([W*0.2, W*0.2, W*0.8, W*0.8], fill=CY + (110,))
glow = glow.filter(ImageFilter.GaussianBlur(W * 0.09))
img = Image.alpha_composite(img.convert("RGBA"), glow)

d = ImageDraw.Draw(img)
cx = cy = W / 2

# ---- orbit: sibling ECUs (multi-ECU future), thin ring + three nodes + spokes to the chip
R_ORB = W * 0.405
d.ellipse([cx - R_ORB, cy - R_ORB, cx + R_ORB, cy + R_ORB], outline=CY_DIM + (110,), width=int(W * 0.004))
node_angles = [-90 - 22, 150 + 8, 30 + 6]  # degrees, slightly off-symmetric = motion
R_CHIP = W * 0.245
for a in node_angles:
    rad = math.radians(a)
    nx, ny = cx + R_ORB * math.cos(rad), cy + R_ORB * math.sin(rad)
    ex, ey = cx + (R_CHIP + W*0.03) * math.cos(rad), cy + (R_CHIP + W*0.03) * math.sin(rad)
    d.line([nx, ny, ex, ey], fill=CY_DIM + (150,), width=int(W * 0.005))
    r = W * 0.036
    d.rounded_rectangle([nx - r, ny - r, nx + r, ny + r], radius=r * 0.3, fill=BG_BOT + (255,), outline=CY + (230,), width=int(W * 0.008))
    rr = r * 0.4
    d.rounded_rectangle([nx - rr, ny - rr, nx + rr, ny + rr], radius=rr * 0.3, fill=CY + (255,))

# ---- chip body with pins
half = R_CHIP
pin_len, pin_w, n_pins = W * 0.05, W * 0.024, 3
for i in range(n_pins):
    t = (i + 0.5) / n_pins
    p = -half + 2 * half * t
    pw = pin_w / 2
    for (x0, y0, x1, y1) in [
        (cx + p - pw, cy - half - pin_len, cx + p + pw, cy - half),   # top
        (cx + p - pw, cy + half, cx + p + pw, cy + half + pin_len),   # bottom
        (cx - half - pin_len, cy + p - pw, cx - half, cy + p + pw),   # left
        (cx + half, cy + p - pw, cx + half + pin_len, cy + p + pw),   # right
    ]:
        d.rounded_rectangle([x0, y0, x1, y1], radius=pw * 0.6, fill=CY + (255,))
d.rounded_rectangle([cx - half, cy - half, cx + half, cy + half], radius=W * 0.045,
                    fill=(0x0B, 0x12, 0x1A, 255), outline=CY + (255,), width=int(W * 0.016))

# ---- tachometer inside the chip: 270° sweep, ticks, needle at high rpm
R_T = half * 0.74
box = [cx - R_T, cy - R_T, cx + R_T, cy + R_T]
start, end = 135, 405
d.arc(box, start, end, fill=CY_DIM + (255,), width=int(W * 0.012))
d.arc(box, start, start + 190, fill=CY + (255,), width=int(W * 0.012))          # "lit" part of the band
red_from = end - 40
d.arc(box, red_from, end, fill=(0xF8, 0x71, 0x71, 255), width=int(W * 0.012))   # redline
for k in range(10):
    a = math.radians(start + (end - start) * k / 9)
    r0, r1 = R_T * 0.80, R_T * 0.90
    col = (0xF8, 0x71, 0x71, 255) if k >= 8 else WHITE + (200,)
    d.line([cx + r0 * math.cos(a), cy + r0 * math.sin(a), cx + r1 * math.cos(a), cy + r1 * math.sin(a)],
           fill=col, width=int(W * 0.007))
needle_a = math.radians(start + (end - start) * 0.78)
nx, ny = cx + R_T * 0.82 * math.cos(needle_a), cy + R_T * 0.82 * math.sin(needle_a)
# tapered needle: wide at the hub, sharp at the tip
pa = needle_a + math.pi / 2; bw = W * 0.013
d.polygon([(cx + bw*math.cos(pa), cy + bw*math.sin(pa)), (nx, ny), (cx - bw*math.cos(pa), cy - bw*math.sin(pa))], fill=WHITE + (255,))
hub = W * 0.028
d.ellipse([cx - hub, cy - hub, cx + hub, cy + hub], fill=CY + (255,))
d.ellipse([cx - hub*0.45, cy - hub*0.45, cx + hub*0.45, cy + hub*0.45], fill=(0x0B, 0x12, 0x1A, 255))

# ---- AI sparkle (four-point star) at the chip's top-right, over the orbit
def star(x, y, r, col):
    pts = []
    for i in range(8):
        a = math.radians(i * 45 - 90); rr = r if i % 2 == 0 else r * 0.32
        pts.append((x + rr * math.cos(a), y + rr * math.sin(a)))
    d.polygon(pts, fill=col)
sx, sy = cx + half * 1.22, cy - half * 1.24
star(sx, sy, W * 0.06, WHITE + (255,))
star(sx + W * 0.075, sy + W * 0.05, W * 0.024, CY + (255,))

out = img.convert("RGB").resize((1024, 1024), Image.LANCZOS)
out.save(sys.argv[1])
print("wrote", sys.argv[1])
