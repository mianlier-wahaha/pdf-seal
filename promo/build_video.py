#!/usr/bin/env python3
"""为 PDF 骑缝章生成一段 ~90 秒的中文宣传视频（含旁白配音、字幕、应用截图与卡片）。"""
import os, subprocess, wave, math, struct, shutil, sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = Path("/Users/mianlier/WorkBuddy/pdf-seal")
OUT  = ROOT / "promo" / "out"
OUT.mkdir(parents=True, exist_ok=True)
SHOTS = ROOT / "screenshots"
FFMPEG = "/Users/mianlier/.workbuddy/binaries/python/envs/default/lib/python3.13/site-packages/imageio_ffmpeg/binaries/ffmpeg-macos-aarch64-v7.1"

W, H = 1920, 1080
FPS = 30
ACCENT  = (214, 40, 40)
BG_TOP  = (15, 22, 32)
BG_BOT  = (5, 7, 10)
TEXT    = (240, 244, 250)
DIM     = (140, 150, 165)

FONT_REG = "/System/Library/Fonts/Hiragino Sans GB.ttc"
FONT_BLD = FONT_REG
F_REG = lambda sz: ImageFont.truetype(FONT_REG, sz, index=0)
F_BLD = lambda sz: ImageFont.truetype(FONT_BLD, sz, index=1)

# 配音：Microsoft Edge 神经 TTS（中文最自然、温暖，免费）
EDGE_VOICE = "zh-CN-XiaoxiaoNeural"   # 温柔自然的中文女声；可选 zh-CN-XiaoyiNeural（更轻柔）/ zh-CN-YunyangNeural（温暖男声）
EDGE_RATE  = "-12%"                   # 略放慢，更舒展温暖（格式必须为 ±N%）
EDGE_PITCH = "-2Hz"                   # 略降半音，听感更柔和温暖

# ────────────────────────────────────────────── 旁白脚本 ──
NARRATION = [
    ("title",
     "还在为投标文件盖章发愁吗？PDF 骑缝章，一款完全免费的 macOS 原生工具，让骑缝章、正文章几分钟搞定。",
     "PDF 骑缝章 — 让盖章这件事，简单一点",
     "macOS 原生 · 纯本地处理 · 完全开源"),
    ("intro",
     "打开或拖入 PDF，界面清晰：左边印章库，中间页面预览，右边参数调节。所有处理都在本机完成，文件不会上传到任何服务器。",
     "把 PDF 拖进来，即刻开始",
     ""),
    ("create",
     "第一次使用，点加号导入章图。白底自动转透明，容错滑杆可调，还能按真实尺寸设定长宽，单位是厘米，盖章大小和实物一致。",
     "一键导入章图：透明化处理 + 实际尺寸（cm）",
     ""),
    ("stamp",
     "骑缝章支持右、左、上、下四个缝位，可以多条错开；正文章点一下就落章，拖动调整位置，右下角控制点缩放大小，右键还能按页删除。",
     "骑缝章 + 正文章，所见即所得",
     ""),
    ("features",
     "三语言界面，深色模式；双指缩放预览、页码跳转；支持保存、另存为；拼合校验视图，能把每页的章条拼回完整印章，一目了然。",
     "功能完整 · 体验顺手",
     "✓ 三语言（简中 / 繁體 / English）  ✓ 跟随系统深色外观\n"
     "✓ 双指缩放 · 状态栏页码跳转  ✓ 保存 / 另存为 / 关闭\n"
     "✓ 拼合校验视图 · 撤销栈 · 快捷键"),
    ("ending",
     "完全开源，代码在 GitHub 上，仓库里提供 dmg 和 zip，下载即用。",
     "开源免费 · 立即下载",
     "github.com/mianlier-wahaha/pdf-seal"),
]

# ────────────────────────────────────────────── 视觉 ──
def gradient_bg(w=W, h=H):
    im = Image.new("RGB", (w, h))
    px = im.load()
    for y in range(h):
        t = y / max(h-1, 1)
        r = int(BG_TOP[0]*(1-t) + BG_BOT[0]*t)
        g = int(BG_TOP[1]*(1-t) + BG_BOT[1]*t)
        b = int(BG_TOP[2]*(1-t) + BG_BOT[2]*t)
        for x in range(w): px[x, y] = (r, g, b)
    # 角落辉光
    glow = Image.new("RGBA", (w, h), (0,0,0,0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse((-300, -300, 700, 700), fill=ACCENT + (32,))
    glow = glow.filter(ImageFilter.GaussianBlur(140))
    im.paste(glow, (0, 0), glow)
    return im

def rounded(im, radius=24):
    mask = Image.new("L", im.size, 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle((0, 0, im.size[0]-1, im.size[1]-1), radius=radius, fill=255)
    out = im.copy(); out.putalpha(mask)
    return out

def with_shadow(im, pad=24, blur=18, alpha=110):
    bg = Image.new("RGBA", (im.size[0]+2*pad, im.size[1]+2*pad), (0,0,0,0))
    sh = Image.new("RGBA", im.size, (0,0,0,alpha))
    bg.paste(sh, (pad, pad), sh)
    bg = bg.filter(ImageFilter.GaussianBlur(blur))
    bg.paste(im, (pad, pad), im)
    return bg

def fit_in(screenshot_path, box):
    src = Image.open(screenshot_path).convert("RGB")
    sw, sh = src.size; bw, bh = box
    s = min(bw/sw, bh/sh)
    nw, nh = int(sw*s), int(sh*s)
    img = src.resize((nw, nh), Image.LANCZOS)
    return img, (int((bw-nw)/2), int((bh-nh)/2))

def wrap_text(draw, text, font, max_w):
    if not text: return []
    chars = list(text)
    lines, cur = [], ""
    for ch in chars:
        cand = cur + ch
        if draw.textlength(cand, font=font) <= max_w or not cur:
            cur = cand
        else:
            lines.append(cur); cur = ch
    if cur: lines.append(cur)
    return lines

def draw_subtitle(base, text):
    if not text: return base
    im = base.convert("RGBA")
    d = ImageDraw.Draw(im)
    font = F_REG(40)
    lines = wrap_text(d, text, font, W*0.78)
    line_h = 58
    box_h = line_h*len(lines) + 40
    bar = Image.new("RGBA", (W, box_h), (10, 14, 22, 180))
    im.paste(bar, (0, H-box_h), bar)
    y = H-box_h + 20
    for line in lines:
        x = (W - d.textlength(line, font=font)) // 2
        d.text((x+2, y+2), line, font=font, fill=(0,0,0,255))
        d.text((x, y), line, font=font, fill=TEXT+(255,))
        y += line_h
    return im.convert("RGB")

def screenshot_card(screenshot_path, caption, subtitle=""):
    base = gradient_bg().convert("RGBA")
    box = (int(W*0.06), 80, int(W*0.94), int(H*0.78))
    img, off = fit_in(screenshot_path, (box[2]-box[0], box[3]-box[1]))
    card = Image.new("RGB", (box[2]-box[0], box[3]-box[1]), (255,255,255))
    card.paste(img, off)
    card = rounded(card.convert("RGBA"), 18)
    shadowed = with_shadow(card)
    base.paste(shadowed, (box[0]-24, box[1]-24))   # RGBA 源 paste 到 RGBA 底
    return draw_subtitle(base, subtitle or caption)

def text_card(title, body_lines):
    base = gradient_bg()
    d = ImageDraw.Draw(base)
    title_font = F_BLD(96)
    x = (W - d.textlength(title, font=title_font)) // 2
    d.text((x+3, 273), title, font=title_font, fill=(0,0,0,200))
    d.text((x, 270), title, font=title_font, fill=ACCENT+(255,))
    body_font = F_REG(46)
    y = 470
    for line in body_lines:
        if line == "":
            y += 30; continue
        for sub in line.split("\n"):
            if not sub.strip():
                y += 18; continue
            tw = d.textlength(sub, font=body_font)
            d.text((((W-tw)//2)+1, y+1), sub, font=body_font, fill=(0,0,0,160))
            d.text(((W-tw)//2, y), sub, font=body_font, fill=TEXT+(255,))
            y += 70
        y += 8
    return base

def title_card():
    base = gradient_bg()
    d = ImageDraw.Draw(base)
    icon = Image.open(ROOT/"scripts/AppIcon_1024.png").convert("RGBA")
    icon = icon.resize((420, 420), Image.LANCZOS)
    base.paste(with_shadow(icon), ((W-420)//2 - 22, 200))
    title_font = F_BLD(128)
    t = "PDF 骑缝章"
    x = (W - d.textlength(t, font=title_font)) // 2
    d.text((x, 660), t, font=title_font, fill=TEXT+(255,))
    sub_font = F_REG(42)
    sub = "macOS 原生 · 纯本地处理 · 完全开源"
    x = (W - d.textlength(sub, font=sub_font)) // 2
    d.text((x, 830), sub, font=sub_font, fill=ACCENT+(255,))
    return base

# ────────────────────────────────────────────── TTS ──
def tts_synth(text, out_mp3):
    import asyncio, edge_tts
    async def _run():
        comm = edge_tts.Communicate(text, EDGE_VOICE, rate=EDGE_RATE, pitch=EDGE_PITCH)
        await comm.save(str(out_mp3))
    asyncio.run(_run())

def wav_dur(path):
    with wave.open(str(path), "rb") as w:
        return w.getnframes() / w.getframerate()

def to_wav(mp3, wav):
    subprocess.run([FFMPEG, "-y", "-loglevel", "error", "-i", str(mp3), "-ar", "44100", "-ac", "2",
                    "-c:a", "pcm_s16le", str(wav)], check=True)
    return wav_dur(wav)

# ────────────────────────────────────────────── ffmpeg 段视频 ──
def build_segment(slide_png, dur, out_mp4, zoom_in=True):
    n = int(dur*FPS)
    expr = "min(zoom+0.0006,1.06)" if zoom_in else "max(1.06-0.0006*on,1.00)"
    flt = (f"scale=3840:-1:force_original_aspect_ratio=increase,crop=3840:2160,"
           f"zoompan=z='{expr}':x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':d={n}:s={W}x{H}:fps={FPS},"
           f"fade=in:st=0:d=0.5,fade=out:st={max(dur-0.5,0):.3f}:d=0.5,format=yuv420p")
    subprocess.run([FFMPEG, "-y", "-loglevel", "error", "-loop", "1", "-i", str(slide_png),
                    "-t", f"{dur:.3f}", "-filter_complex", flt,
                    "-c:v", "libx264", "-preset", "medium", "-crf", "18",
                    "-pix_fmt", "yuv420p", str(out_mp4)], check=True)

# ────────────────────────────────────────────── 主流程 ──
def main():
    tmp = OUT/"_tmp"; tmp.mkdir(exist_ok=True)
    audio_segments = []
    durations = []
    slide_paths = []
    zoom_dirs = [True, True, True, True, True, False]
    sources = [
        ("title",   None, None, NARRATION[0][2], NARRATION[0][3]),
        ("intro",   SHOTS/"main-empty.png",     None, NARRATION[1][2], NARRATION[1][3]),
        ("create",  SHOTS/"seal-create.png",    None, NARRATION[2][2], NARRATION[2][3]),
        ("stamp",   SHOTS/"iShot_2026-09-05_01.27.03.png", None, NARRATION[3][2], NARRATION[3][3]),
        ("features", None, NARRATION[4][3].split("\n"), NARRATION[4][2], ""),
        ("ending",  None, None, NARRATION[5][2], NARRATION[5][3]),
    ]
    print("→ 生成 6 张画面")
    for i, (key, shot, body_lines, caption, subtitle) in enumerate(sources):
        if key == "title":
            im = title_card()
        elif shot is not None:
            im = screenshot_card(shot, caption, subtitle if subtitle else caption)
        else:
            im = text_card(caption, body_lines or [subtitle])
        sp = tmp/f"slide_{i:02d}.png"
        im.save(sp); slide_paths.append(sp)
    print("→ 生成 6 段配音")
    for i, (_, _, _, _, _) in enumerate(sources):
        narr = NARRATION[i][1]
        mp3 = tmp/f"voice_{i:02d}.mp3"
        tts_synth(narr, mp3)
        wav = tmp/f"voice_{i:02d}.wav"
        d = to_wav(mp3, wav)
        audio_segments.append((wav, d))
        durations.append(max(d + 1.0, 5.0))
        print(f"  {i+1}. {d:.2f}s → 时长 {durations[-1]:.2f}s")
    print("→ 生成 6 个视频段（Ken Burns + 淡入淡出）")
    seg_mp4s = []
    for i, (sp, dur, zd) in enumerate(zip(slide_paths, durations, zoom_dirs)):
        seg = tmp/f"seg_{i:02d}.mp4"
        build_segment(sp, dur, seg, zoom_in=zd)
        seg_mp4s.append(seg)
    print("→ 拼接视频（xfade 转场 0.6s）")
    TRANS = 0.6
    n = len(seg_mp4s)
    inputs = []; args = []
    for i, s in enumerate(seg_mp4s): inputs.extend(["-i", str(s)])
    flt = [f"[0:v]format=yuv420p[v0]"]
    for i in range(1, n):
        off = sum(durations[:i]) - TRANS*i
        prev = "v0" if i == 1 else f"vx{i-1}"
        flt.append(f"[{prev}][{i}:v]xfade=transition=fade:duration={TRANS}:offset={off:.3f}[vx{i}]")
    flt.append(f"[vx{n-1}]format=yuv420p[vout]")
    fc = ";".join(flt)
    print(fc[:200] + "...")
    merged_video = tmp/"merged.mp4"
    subprocess.run([FFMPEG, "-y", "-loglevel", "error"] + inputs +
                    ["-filter_complex", fc, "-map", "[vout]",
                     "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-r", str(FPS),
                     str(merged_video)], check=True)
    video_total = sum(durations) - TRANS*(n-1)
    print(f"→ 合成配音轨道（总长 {video_total:.2f}s）")
    SR = 44100; CH = 2
    total = int(round(video_total*SR))
    audio = bytearray(total*CH*2)
    for i, (wav, d) in enumerate(audio_segments):
        if i == 0:
            offset = 0.6  # 与画面 lead 一致
        else:
            offset = sum(durations[:i]) - TRANS*i + 0.6
        start = int(round(offset*SR))
        with wave.open(str(wav), "rb") as w:
            nframes = w.getnframes(); fr = w.getframerate(); nch = w.getnchannels(); sw = w.getsampwidth()
            assert fr == SR and nch == CH and sw == 2, f"audio format {fr}/{nch}/{sw}"
            data = w.readframes(nframes)
        end = min(start + nframes, total)
        pos = (start*CH*2) - start*CH*2  # dummy
        # write into audio bytes
        seg_len = (end - start) * CH * 2
        audio[start*CH*2: start*CH*2 + seg_len] = data[:seg_len]
    final_wav = OUT/"_narration.wav"
    with wave.open(str(final_wav), "wb") as w:
        w.setnchannels(CH); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(bytes(audio))
    final_mp4 = OUT/"PDF骑缝章-介绍.mp4"
    print("→ 合成最终视频")
    subprocess.run([FFMPEG, "-y", "-loglevel", "error", "-i", str(merged_video),
                    "-i", str(final_wav), "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
                    "-shortest", str(final_mp4)], check=True)
    print("✓ 完成:", final_mp4, "大小", os.path.getsize(final_mp4)//1024, "KB")
    shutil.rmtree(tmp)

if __name__ == "__main__":
    main()