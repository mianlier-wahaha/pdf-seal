#!/usr/bin/env python3
# 生成 mPDF 图标矢量源（与 make_icon.swift 同构）
import math

# 印章（圆环 + 五角星）中心，CG 坐标 (158,158) -> SVG 翻转 y
cx, cy = 158, 1024 - 158          # (158, 866)
ring_r = 88
star_r1, star_r2 = 40, 17

star_pts = []
for k in range(10):
    ang = -math.pi / 2 + k * (math.pi / 5)
    r = star_r1 if k % 2 == 0 else star_r2
    star_pts.append((cx + r * math.cos(ang), cy + r * math.sin(ang)))
star_d = "M " + " L ".join(f"{x:.1f} {y:.1f}" for x, y in star_pts) + " Z"

# 粗几何 m：两段拱形 + 三根竖腿（SVG y 向下，拱用二次贝塞尔保证朝上）
m_d = (
    "M 300 764 L 300 464 Q 400 264 500 464 L 500 764 "
    "M 500 464 Q 600 264 700 464 L 700 764"
)

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  <defs>
    <style>
      .mark {{ font-family: "Helvetica Neue", Helvetica, Arial, sans-serif; font-weight: 700; }}
    </style>
  </defs>
  <rect x="0" y="0" width="1024" height="1024" rx="230" ry="230" fill="#D62421"/>
  <text class="mark" x="962" y="252" text-anchor="end" font-size="150"
        letter-spacing="-3" fill="#ffffff">PDF</text>
  <path d="{m_d}" fill="none" stroke="#ffffff" stroke-width="96"
        stroke-linecap="butt" stroke-linejoin="round"/>
  <circle cx="{cx}" cy="{cy}" r="{ring_r}" fill="none" stroke="#ffffff" stroke-width="15"/>
  <path d="{star_d}" fill="#ffffff"/>
</svg>
'''

with open("scripts/mpdf-icon.svg", "w", encoding="utf-8") as f:
    f.write(svg)
print("svg written:", len(svg), "bytes")
