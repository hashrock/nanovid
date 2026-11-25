"""ストア用スクリーンショットのデモ書類を作る。

使い方: python3 -I make_demo.py <demo ディレクトリ> <ベースの project.json> <ja|en>
<demo>/img/{01-intro,02-grind,03-pour}.png を素材にし、<demo>/<lang>/ に
動画・音楽と 2 つの書類を書く（<名前>.nanovid＝BGM あり、silence/<名前>.nanovid＝BGM なし。
無音カットは BGM があると間を見つけられないので、02・03 は BGM なしで撮る）。
"""
import copy
import json
import subprocess
import sys
import uuid
from pathlib import Path

demo = Path(sys.argv[1])
base = json.load(open(sys.argv[2]))
lang = sys.argv[3]
out = demo / lang
out.mkdir(parents=True, exist_ok=True)

SCENE = 14.0
if lang == "ja":
    voice = "Kyoko"
    name = "ハンドドリップ入門"
    title, sub = "ハンドドリップ入門", "おうちで淹れる、いつもの一杯"
    steps = ["STEP 1　豆を挽く", "STEP 2　お湯を注ぐ"]
    lines = [
        ["今日はハンドドリップの淹れ方を紹介します", "用意するのは豆とドリッパーだけ", "お湯は 92 度くらいがおすすめです"],
        ["豆は中挽きにします", "1 杯ぶんで 15 グラムが目安", "挽きたては香りが違います"],
        ["まず少量のお湯で蒸らします", "円を描くようにゆっくり注ぎます", "3 分ほどで淹れ終わります", "いただきます"],
    ]
    track_names = {"subs": "字幕（自動）"}
else:
    voice = "Samantha"
    name = "Pour-Over Basics"
    title, sub = "Pour-Over Basics", "A simple cup of coffee at home"
    steps = ["STEP 1  Grind the beans", "STEP 2  Pour the water"]
    lines = [
        ["Today, let's brew a pour-over coffee", "All you need is beans and a dripper", "Water at about 92°C works best"],
        ["Grind the beans medium", "Use about 15 grams per cup", "Freshly ground beans smell better"],
        ["First, let it bloom with a little water", "Then pour slowly in circles", "It's ready in about three minutes", "Enjoy"],
    ]
    track_names = {"subs": "Subtitles (Auto)"}


def run(*args):
    subprocess.run(args, check=True)


def duration(path):
    r = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
                       check=True, capture_output=True, text=True)
    return float(r.stdout.strip())


# ナレーションを読み上げて、場面ごとに間を空けて並べる。
subs = []  # (start, duration, text)
scene_files = []
for si, scene_lines in enumerate(lines):
    placed = []
    t = 0.6
    for li, text in enumerate(scene_lines):
        aiff = out / f"voice-{si}-{li}.aiff"
        run("say", "-v", voice, "-r", "185", "-o", str(aiff), text.replace("°C", " degrees"))
        d = duration(aiff)
        placed.append((t, d, aiff))
        subs.append((si * SCENE + t, round(d + 0.2, 2), text))
        t += d + 1.0
    assert t < SCENE + 0.5, (si, t)
    img = demo / "img" / ["01-intro", "02-grind", "03-pour"][si]
    mp4 = out / f"{img.name}.mp4"
    inputs = []
    filters = []
    for i, (start, _, aiff) in enumerate(placed):
        inputs += ["-i", str(aiff)]
        ms = int(start * 1000)
        filters.append(f"[{i + 1}:a]aresample=48000,adelay={ms}|{ms}[a{i}]")
    mix = "".join(f"[a{i}]" for i in range(len(placed)))
    filters.append(f"{mix}amix=inputs={len(placed)}:normalize=0,apad,atrim=0:{SCENE},volume=1.4[aout]")
    run("ffmpeg", "-loglevel", "error", "-y", "-loop", "1", "-framerate", "30", "-i", f"{img}.png", *inputs,
        "-filter_complex", ";".join(filters), "-map", "0:v", "-map", "[aout]", "-t", str(SCENE),
        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-r", "30", "-c:a", "aac", "-ac", "2", str(mp4))
    scene_files.append(mp4)

# BGM（やわらかい和音を 4 つ回す）。
music = out / "music.m4a"
chords = [(261.6, 329.6, 392.0), (220.0, 261.6, 329.6), (174.6, 220.0, 261.6), (196.0, 246.9, 293.7)]
expr = []
for i, ch in enumerate(chords):
    tone = "+".join(f"sin(2*PI*{f}*t)" for f in ch)
    expr.append(f"(between(mod(t,8),{i * 2},{i * 2 + 2})*({tone})*0.05*(1-0.5*mod(t,2)/2))")
run("ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
    f"aevalsrc='{'+'.join(expr)}':s=48000:d={SCENE * 3}", "-af", "afade=t=in:d=1,afade=t=out:st=40:d=2",
    "-c:a", "aac", "-ac", "2", str(music))


def nid():
    return str(uuid.uuid4()).upper()


def clip(start, dur, content, name="", fade=(0, 0), volume=1):
    return {"content": content, "duration": dur, "fade": {"inDuration": fade[0], "outDuration": fade[1]},
            "id": nid(), "name": name, "opacity": 1, "start": start,
            "transform": {"position": [0, 0], "rotation": 0, "scale": 1}, "volume": volume}


def text(template, props, start, dur, fade=(0, 0)):
    p = {}
    for k, v in props.items():
        p[k] = {"color": {"_0": v}} if isinstance(v, dict) else {"string": {"_0": v}}
    return clip(start, dur, {"text": {"_0": {"props": p, "templateID": template}}}, fade=fade)


def asset(path, kind, dur, video=True, audio=True):
    a = {"displayName": path.stem, "duration": dur, "hasAudio": audio, "hasVideo": video,
         "id": nid(), "kind": kind, "path": str(path)}
    if video:
        a["naturalSize"] = [1280, 720]
    return a


def project(with_music):
    p = copy.deepcopy(base)
    p["name"] = name
    p["canvas"].update({"width": 1280, "height": 720, "fps": 30})
    tpl = {t["name"]: t["id"] for t in p["textTemplates"]}
    video, telop, audio = [copy.deepcopy(t) for t in p["tracks"]]
    for t in (video, telop, audio):
        t["clips"] = []
        t["id"] = nid()
    p["assets"] = []
    for i, f in enumerate(scene_files):
        a = asset(f, "video", SCENE)
        p["assets"].append(a)
        video["clips"].append(clip(i * SCENE, SCENE, {"media": {"assetID": a["id"], "sourceStart": 0}}, name=f.stem))
    brown = {"r": 0.32, "g": 0.2, "b": 0.13, "a": 1}
    orange = {"r": 0.84, "g": 0.42, "b": 0.18, "a": 1}
    telop["clips"].append(text(tpl["タイトル"], {"title": title, "subtitle": sub, "titleColor": brown, "accent": orange},
                               0.2, 3.1, fade=(0.4, 0.4)))
    for i, s in enumerate(steps):
        telop["clips"].append(text(tpl["テロップ（左下）"], {"text": s}, (i + 1) * SCENE + 0.2, 4.2))
    subs_track = copy.deepcopy(telop)
    subs_track["id"] = nid()
    subs_track["name"] = track_names["subs"]
    subs_track["clips"] = [text(tpl["字幕"], {"text": s}, round(st, 2), d) for st, d, s in subs]
    if with_music:
        m = asset(music, "audio", SCENE * 3, video=False)
        p["assets"].append(m)
        audio["clips"].append(clip(0, SCENE * 3, {"media": {"assetID": m["id"], "sourceStart": 0}},
                                   name="music", fade=(1, 2), volume=0.6))
    p["tracks"] = [video, telop, subs_track, audio]
    return p


for fname, with_music in [("main", True), ("silence", False)]:
    pkg = out / f"{name}.nanovid" if fname == "main" else out / "silence" / f"{name}.nanovid"
    pkg.mkdir(parents=True, exist_ok=True)
    json.dump(project(with_music), open(pkg / "project.json", "w"), ensure_ascii=False, indent=2)
    print(pkg)
