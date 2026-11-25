"""2 倍で描いた窓（ShotCapture の出力）を、前回と同じ背景に置いて 2880x1800 にする。

使い方: python3 -I compose.py <撮影ディレクトリ> <出力.png> [メニューの左上 x,y（窓の中の pt）]

- 背景: 前回のストア画像から測った 4 隅の色の双一次グラデーション
- 窓: 2560x1600 を (160, 100) に置く。角を半径 26pt で丸め、影を付ける
- 信号機: アプリを前に出さずに描くので灰色になる。前面の窓の色で塗り直す
- シート: windows.json の位置で窓の上に重ねる
- メニュー: <撮影>/menu/ に外から撮った下敷きの窓とメニューがあれば、切り抜いて重ねる
"""
import json
import sys
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

shot = Path(sys.argv[1])
out = sys.argv[2]
menu_at = tuple(float(v) for v in sys.argv[3].split(",")) if len(sys.argv) > 3 else None

W, H = 2880, 1800
TL, TR, BL, BR = (238, 244, 255), (204, 210, 240), (209, 215, 242), (188, 194, 236)


def gradient():
    small = Image.new("RGB", (2, 2))
    small.putpixel((0, 0), TL)
    small.putpixel((1, 0), TR)
    small.putpixel((0, 1), BL)
    small.putpixel((1, 1), BR)
    return small.resize((W, H), Image.BILINEAR)


def rounded_mask(size, radius):
    scale = 4
    m = Image.new("L", (size[0] * scale, size[1] * scale), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size[0] * scale - 1, size[1] * scale - 1], radius * scale, fill=255)
    return m.resize(size, Image.LANCZOS)


def shadow_onto(canvas, mask, at, blur, offset, opacity):
    sh = Image.new("L", canvas.size, 0)
    sh.paste(mask, (at[0] + offset[0], at[1] + offset[1]))
    sh = sh.filter(ImageFilter.GaussianBlur(blur)).point(lambda v: int(v * opacity))
    canvas.paste(Image.new("RGB", canvas.size, (20, 22, 40)), (0, 0), sh)


entries = json.load(open(shot / "windows.json"))
main = max((e for e in entries if e["level"] == 0), key=lambda e: e["w"] * e["h"])
win = Image.open(main["file"]).convert("RGBA")
assert win.size == (2560, 1600), win.size

# 信号機を前面の窓の色で塗る（下で）。
# ツールバーのボタンの下地（ガラス）は cacheDisplay で描かれないので、等倍で撮った本物の
# 形と色（247）で敷く。真っ白の画素だけ塗るので、アイコンは残る。
cap = Image.new("L", win.size, 0)
cd = ImageDraw.Draw(cap)
cd.rounded_rectangle([192, 16, 272, 86], 35, fill=255)
cd.rounded_rectangle([2392, 16, 2540, 86], 35, fill=255)
white = Image.eval(win.convert("L"), lambda v: 255 if v == 255 else 0)
win.paste((247, 247, 247, 255), (0, 0), ImageChops.multiply(cap, white))
d = ImageDraw.Draw(win)
for cx, color, ring in [(52.5, (255, 95, 87), (226, 70, 63)), (100.5, (254, 188, 46), (223, 157, 35)),
                        (148.5, (40, 200, 64), (30, 165, 50))]:
    d.ellipse([cx - 14, 51 - 14, cx + 14, 51 + 14], fill=ring)
    d.ellipse([cx - 13, 51 - 13, cx + 13, 51 + 13], fill=color)

# シート（窓より手前のもの）を重ねる。座標は左下原点の pt。
for e in entries:
    if e is main:
        continue
    sheet = Image.open(e["file"]).convert("RGBA")
    if e["x"] == 0 and e["y"] == 0:
        # シートの窓は位置が (0,0) のまま返る。前回の画像と同じく、窓の真ん中に置く。
        x, y = (win.size[0] - sheet.size[0]) // 2, (win.size[1] - sheet.size[1]) // 2
    else:
        x = round((e["x"] - main["x"]) * 2)
        y = round(((main["y"] + main["h"]) - (e["y"] + e["h"])) * 2)
    smask = rounded_mask(sheet.size, 2 * 18)
    layer = Image.new("RGBA", win.size, (0, 0, 0, 0))
    sh = Image.new("L", win.size, 0)
    sh.paste(smask, (x, y + 16))
    sh = sh.filter(ImageFilter.GaussianBlur(36)).point(lambda v: int(v * 0.35))
    win = Image.composite(Image.new("RGBA", win.size, (0, 0, 0, 255)), win, sh)
    layer.paste(sheet, (x, y), smask)
    win = Image.alpha_composite(win, layer)

# メニュー: 下敷きの窓（無地）の上で、文字を 2 倍にして等倍で撮ったもの。
menu_dir = shot / "menu"
if menu_at and (menu_dir / "windows.json").exists():
    ms = json.load(open(menu_dir / "windows.json"))
    menu = next(e for e in ms if e["layer"] > 0)
    backdrop = next(e for e in ms if e["layer"] == 0 and e["w"] < 1000)
    img = Image.open(backdrop["file"]).convert("RGBA")
    box = (round(menu["x"] - backdrop["x"]), round(menu["y"] - backdrop["y"]))
    crop = img.crop((box[0], box[1], box[0] + round(menu["w"]), box[1] + round(menu["h"])))
    mmask = rounded_mask(crop.size, 24)
    # 窓の右端（内側 12pt）からはみ出さないよう、左へ寄せる。
    px = min(round(menu_at[0] * 2), win.size[0] - 24 - crop.size[0])
    py = round(menu_at[1] * 2)
    sh = Image.new("L", win.size, 0)
    sh.paste(mmask, (px, py + 10))
    sh = sh.filter(ImageFilter.GaussianBlur(22)).point(lambda v: int(v * 0.30))
    win = Image.composite(Image.new("RGBA", win.size, (0, 0, 0, 255)), win, sh)
    layer = Image.new("RGBA", win.size, (0, 0, 0, 0))
    layer.paste(crop, (px, py), mmask)
    win = Image.alpha_composite(win, layer)

# 角を丸めて、縁に細い線を引く。
mask = rounded_mask(win.size, 52)
edge = ImageChops.subtract(mask, mask.filter(ImageFilter.MinFilter(3))).point(lambda v: int(v * 0.25))
win.putalpha(mask)
outline = Image.new("RGBA", win.size, (0, 0, 0, 255))
outline.putalpha(edge)
win = Image.alpha_composite(win, outline)

canvas = gradient()
at = (160, 100)
shadow_onto(canvas, mask, at, 60, (0, 36), 0.45)
shadow_onto(canvas, mask, at, 6, (0, 4), 0.25)
canvas.paste(win, at, win)
canvas.save(out)
print(out)
