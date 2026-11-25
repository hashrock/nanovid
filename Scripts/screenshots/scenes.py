"""デモ動画の 3 場面（1280x720 の静止画）を描く。使い方: python3 -I scenes.py <出力ディレクトリ>"""
import sys
from PIL import Image, ImageDraw, ImageFilter

W, H = 1280, 720
out = sys.argv[1]


def steam(img, cx, top, n=3):
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for i in range(n):
        x = cx - 30 + i * 30
        d.ellipse([x - 26, top - 120 + i * 10, x + 26, top - 20], fill=(255, 255, 255, 70))
    layer = layer.filter(ImageFilter.GaussianBlur(18))
    img.alpha_composite(layer)


def beans(d, pts, color=(92, 58, 38)):
    for x, y in pts:
        d.ellipse([x - 11, y - 7, x + 11, y + 7], fill=color)
        d.line([x - 6, y, x + 6, y], fill=(60, 36, 22), width=2)


def intro():
    img = Image.new("RGBA", (W, H), (246, 224, 190, 255))
    d = ImageDraw.Draw(img)
    # 窓
    d.rounded_rectangle([830, 70, 1150, 420], 16, fill=(253, 244, 228))
    d.rounded_rectangle([850, 90, 985, 400], 8, fill=(190, 226, 238))
    d.rounded_rectangle([1000, 90, 1130, 400], 8, fill=(190, 226, 238))
    d.ellipse([1040, 130, 1100, 190], fill=(255, 222, 130))
    # 棚と小物
    d.rounded_rectangle([110, 160, 500, 176], 6, fill=(196, 140, 92))
    d.rounded_rectangle([150, 100, 210, 160], 6, fill=(229, 132, 96))
    for i, c in enumerate([(104, 160, 112), (90, 148, 100), (112, 170, 120)]):
        d.ellipse([150 + i * 18, 30, 178 + i * 18, 110], fill=c)
    d.rounded_rectangle([280, 80, 320, 160], 4, fill=(66, 96, 140))
    d.rounded_rectangle([330, 110, 362, 160], 4, fill=(238, 128, 80))
    d.rounded_rectangle([372, 70, 404, 160], 4, fill=(160, 198, 226))
    # カウンター
    d.rectangle([0, 520, W, H], fill=(214, 160, 104))
    d.rectangle([0, 520, W, 532], fill=(196, 140, 86))
    # カップ
    d.ellipse([480, 600, 800, 650], fill=(250, 244, 232))
    d.rounded_rectangle([540, 440, 720, 625], 22, fill=(248, 244, 236))
    d.ellipse([700, 480, 770, 570], outline=(240, 234, 222), width=16)
    d.ellipse([548, 428, 712, 456], fill=(110, 70, 46))
    steam(img, 630, 430)
    d = ImageDraw.Draw(img)
    beans(d, [(360, 620), (400, 600), (880, 615), (920, 640), (300, 650)])
    return img


def grind():
    img = Image.new("RGBA", (W, H), (205, 222, 210, 255))
    d = ImageDraw.Draw(img)
    d.ellipse([-120, -160, 380, 300], fill=(214, 230, 218))
    d.ellipse([900, 120, 1400, 620], fill=(214, 230, 218))
    d.rectangle([0, 520, W, H], fill=(140, 98, 70))
    d.rectangle([0, 520, W, 534], fill=(122, 84, 58))
    # 豆の袋
    d.polygon([(250, 260), (400, 260), (420, 560), (230, 560)], fill=(236, 214, 178))
    d.rectangle([250, 245, 400, 275], fill=(226, 200, 160))
    d.rounded_rectangle([280, 360, 370, 440], 12, fill=(150, 110, 80))
    d.ellipse([310, 385, 340, 415], fill=(236, 214, 178))
    # ミル
    d.rounded_rectangle([540, 340, 760, 560], 18, fill=(150, 98, 64))
    d.rounded_rectangle([580, 430, 720, 500], 8, fill=(116, 72, 46))
    d.ellipse([635, 455, 665, 475], fill=(210, 170, 120))
    d.polygon([(560, 340), (740, 340), (700, 270), (600, 270)], fill=(196, 196, 200))
    d.rectangle([645, 200, 655, 270], fill=(120, 120, 126))
    d.line([650, 205, 790, 160], fill=(120, 120, 126), width=10)
    d.ellipse([780, 145, 812, 177], fill=(236, 120, 84))
    # 皿と豆
    d.ellipse([830, 500, 1010, 545], fill=(250, 246, 236))
    d.ellipse([850, 495, 990, 530], fill=(110, 70, 46))
    beans(d, [(880, 512), (920, 506), (960, 514)])
    return img


def pour():
    img = Image.new("RGBA", (W, H), (236, 226, 244, 255))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([90, 90, 400, 330], 14, fill=(248, 240, 252))
    d.line([245, 90, 245, 330], fill=(226, 214, 236), width=8)
    d.rectangle([0, 540, W, H], fill=(228, 196, 150))
    d.rectangle([0, 540, W, 552], fill=(210, 176, 128))
    # サーバーとドリッパー
    d.rounded_rectangle([560, 420, 760, 600], 30, fill=(214, 232, 240))
    d.rectangle([575, 500, 745, 590], fill=(120, 76, 48))
    d.polygon([(540, 320), (780, 320), (700, 420), (620, 420)], fill=(250, 250, 250))
    d.rectangle([540, 310, 780, 324], fill=(240, 240, 240))
    # ケトル
    d.rounded_rectangle([830, 160, 1080, 330], 40, fill=(70, 74, 82))
    d.arc([880, 100, 1040, 240], 180, 360, fill=(70, 74, 82), width=14)
    d.line([840, 280, 720, 220], fill=(70, 74, 82), width=16)
    # お湯
    d.line([716, 222, 662, 318], fill=(200, 230, 246), width=6)
    steam(img, 660, 320, n=2)
    return img


for name, f in [("01-intro", intro), ("02-grind", grind), ("03-pour", pour)]:
    f().convert("RGB").save(f"{out}/{name}.png")
    print(name)
