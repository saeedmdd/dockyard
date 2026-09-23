import sys

AMBER = ("#FFD99C", "#F5A63A", "#C97F16")
STEEL = ("#EDF3FA", "#C2D1E3", "#93A6BE")

def build(tiers, hw, dy, h, corrugation, seam_w, pad):
    palette = [AMBER, STEEL, AMBER][:tiers] if tiers == 3 else [AMBER, STEEL]
    total = tiers * h
    top_cy = 512 - (total + 2 * dy) / 2 + dy
    parts = []
    for i in range(tiers):
        cy = top_cy + i * h
        top, left, right = palette[i]
        if i == 0:
            parts.append(f'<polygon points="512,{cy-dy:.0f} {512+hw},{cy:.0f} 512,{cy+dy:.0f} {512-hw},{cy:.0f}" fill="{top}"/>')
        parts.append(f'<polygon points="{512-hw},{cy:.0f} 512,{cy+dy:.0f} 512,{cy+dy+h:.0f} {512-hw},{cy+h:.0f}" fill="{left}"/>')
        parts.append(f'<polygon points="512,{cy+dy:.0f} {512+hw},{cy:.0f} {512+hw},{cy+h:.0f} 512,{cy+dy+h:.0f}" fill="{right}"/>')
        if corrugation:
            lines = []
            for k in range(1, 5):
                t = k / 5
                x = 512 - hw + hw * t; y = cy + dy * t
                lines.append(f'<line x1="{x:.0f}" y1="{y:.0f}" x2="{x:.0f}" y2="{y+h:.0f}"/>')
                x2 = 512 + hw - hw * t
                lines.append(f'<line x1="{x2:.0f}" y1="{y:.0f}" x2="{x2:.0f}" y2="{y+h:.0f}"/>')
            parts.append('<g stroke="#0000001f" stroke-width="6">' + "".join(lines) + '</g>')
        parts.append(
            f'<polyline points="{512-hw},{cy:.0f} 512,{cy+dy:.0f} {512+hw},{cy:.0f}" '
            f'fill="none" stroke="#00000038" stroke-width="{seam_w}"/>'
        )
    body = "\n    ".join(parts)
    r = 832 * 0.2237
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#4C8DF6"/>
      <stop offset="0.55" stop-color="#2657C4"/>
      <stop offset="1" stop-color="#122B66"/>
    </linearGradient>
  </defs>
  <rect x="{pad}" y="{pad}" width="{1024-2*pad}" height="{1024-2*pad}" rx="{r:.0f}" ry="{r:.0f}" fill="url(#bg)"/>
    {body}
</svg>'''

# Full detail for anything 128px and up.
open("icon-large.svg","w").write(build(tiers=3, hw=240, dy=112, h=120, corrugation=True, seam_w=8, pad=96))
# Bolder, fewer parts, no corrugation — survives 16 and 32 px.
open("icon-small.svg","w").write(build(tiers=2, hw=268, dy=126, h=176, corrugation=False, seam_w=18, pad=72))
