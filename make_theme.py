#!/usr/bin/env python3
"""Make a launcher theme (logo, backdrops, music, menu sounds) from YOUR OWN copy of a game.

    .venv/bin/python make_theme.py <game> <built game app or launcher .app> [--cover image] [--out folder]

<game> is one of: suikoden, shiningpearl, pokopia, fireemblem, oot, firered
The game app is the one nxnative built (or a launcher that has it inside Contents/Game).
Everything is read from that app's own game files (romfs.img) and its icon; nothing is downloaded.
The result is a theme folder (default: themes/<game>/) that build-launcher.sh turns into an app.
Nothing this writes may be shared: it is the game's own art and audio.
"""
import argparse, glob, io, json, os, re, shutil, struct, subprocess, sys, tempfile

KIT = os.path.dirname(os.path.abspath(__file__))
NX = os.path.expanduser(os.environ.get("NXNATIVE", "~/nxnative"))
sys.path.insert(0, os.path.join(NX, "dm/tools"))
sys.path.insert(0, os.path.join(KIT, "tools"))
try:
    import romfs  # nxnative's reader for the game file image
except ImportError:
    sys.exit(f"nxnative not found at {NX} (set NXNATIVE=…)")
from PIL import Image, ImageDraw, ImageFilter


def tool(name):
    p = shutil.which(name) or f"/opt/homebrew/bin/{name}"
    if not os.path.exists(p): sys.exit(f"{name} not found: run setup.sh")
    return p


VG, FF = tool("vgmstream-cli"), tool("ffmpeg")


def run(*args, quiet=True):
    r = subprocess.run([str(a) for a in args], capture_output=True, text=True)
    if r.returncode and not quiet: print(r.stdout[-2000:], r.stderr[-2000:])
    return r


# ---------------------------------------------------------------- game files

class Game:
    def __init__(self, app):
        app = os.path.abspath(app)
        inner = sorted(glob.glob(os.path.join(glob.escape(app), "Contents/Game/*.app")))   # names may hold [ ]
        self.app = inner[0] if inner else app        # a launcher: use the game app inside it
        spots = ["Contents/PlugIns/GameData.bundle/Contents/Resources/romfs.img", "Contents/Resources/romfs.img"]
        self.img = next((os.path.join(self.app, s) for s in spots if os.path.exists(os.path.join(self.app, s))), None)
        if not self.img: sys.exit(f"no game files in {self.app} (is it an nxnative-built app?)")
        self._index = None

    def read(self, path):
        with romfs.Path(self.img + path).open("rb") as f: return f.read()

    def save(self, path, dest):
        open(dest, "wb").write(self.read(path)); return dest

    def find(self, name):
        """Path of the first file called `name` anywhere in the game files."""
        if self._index is None:
            self._index = {}
            for root, dirs, files in romfs.walk(self.img):
                for f in files: self._index.setdefault(f, root[len(self.img):] + "/" + f)
        if name not in self._index: sys.exit(f"{name} not found in the game files (different game or version?)")
        return self._index[name]

    def icon(self, dest):
        run("sips", "-s", "format", "png", os.path.join(self.app, "Contents/Resources/AppIcon.icns"), "--out", dest)
        return Image.open(dest).convert("RGB")


def m4a(src, dest, stereo=True):
    args = [FF, "-v", "error", "-y", "-i", src] + (["-ac", "2"] if stereo else []) + ["-c:a", "aac", "-b:a", "192k", dest]
    r = run(*args)
    if r.returncode or not os.path.exists(dest): sys.exit(f"could not convert {src}: {r.stderr[-300:]}")


def vg_wav(src, dest, sub=None, once=True):
    args = [VG] + (["-s", str(sub)] if sub else []) + (["-i"] if once else []) + ["-o", dest, src]
    r = run(*args)
    if not os.path.exists(dest): sys.exit(f"vgmstream could not decode {os.path.basename(src)} {sub or ''}: {r.stdout[-300:]}")
    return dest


def loop_start(src, sub=None):
    out = run(VG, "-m", *(["-s", str(sub)] if sub else []), src).stdout
    m = re.search(r"loop start: \d+ samples \((\d+):(\d+\.\d+) seconds\)", out)
    return round(int(m[1]) * 60 + float(m[2]), 3) if m else None


def frames_every(movie, outdir, seconds, prefix):
    """Decode a whole movie and keep one full-size frame every `seconds` (seeking breaks on some AV1 files)."""
    run(FF, "-v", "quiet", "-i", movie, "-vf", f"fps=1/{seconds}", "-q:v", "3", os.path.join(outdir, f"{prefix}_%03d.jpg"))


def frame_at(movie, t, dest):
    run(FF, "-v", "error", "-ss", str(t), "-i", movie, "-frames:v", "1", "-q:v", "3", "-y", dest)
    if not os.path.exists(dest): sys.exit(f"no frame at {t}s in {movie}")


def keep_big_pieces(mask, min_size):
    """Drop specks: keep only connected parts of a 0/255 mask bigger than min_size pixels."""
    W, H = mask.size; mp = mask.load(); lab = [[0] * W for _ in range(H)]; keep = set(); nid = 0
    for y in range(H):
        for x in range(W):
            if mp[x, y] == 255 and not lab[y][x]:
                nid += 1; st = [(x, y)]; lab[y][x] = nid; n = 0
                while st:
                    cx, cy = st.pop(); n += 1
                    for nx, ny in ((cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)):
                        if 0 <= nx < W and 0 <= ny < H and mp[nx, ny] == 255 and not lab[ny][nx]:
                            lab[ny][nx] = nid; st.append((nx, ny))
                if n >= min_size: keep.add(nid)
    out = Image.new("L", (W, H)); op = out.load()
    for y in range(H):
        for x in range(W):
            if lab[y][x] in keep: op[x, y] = 255
    return out


def cut(img, mask, dest, blur=0.8):
    mask = mask.filter(ImageFilter.GaussianBlur(blur))
    o = img.convert("RGBA"); o.putalpha(mask); o = o.crop(mask.getbbox()); o.save(dest); return o


# ---------------------------------------------------------------- recipes

def suikoden(g, out, tmp, args):
    raw = os.path.join(tmp, "raw")
    env = dict(os.environ, UNITY_VERSION="2022.3.28f1")
    subprocess.run([sys.executable, "-I", os.path.join(KIT, "tools/unity_art.py"), g.img, raw, "title-texture|gallery-omake"], env=env, check=True)
    shutil.copy(os.path.join(raw, "S_UI_Top_Title02_006.png"), os.path.join(out, "logo.png"))
    for i, n in enumerate(["265", "090", "076", "086", "096", "262", "098", "080", "074", "073"], 1):
        shutil.copy(os.path.join(raw, f"S_omake_{n}.png"), os.path.join(out, f"bg{i}.png"))
    snd = "/Data/StreamingAssets/Sound/"
    for p in ["BGM1/SD_STR_TITLE.acb", "BGM1/SD_STR_TITLE.awb", "GAME_START_SE.acb"]:
        g.save(snd + p, os.path.join(tmp, os.path.basename(p)))
    m4a(vg_wav(os.path.join(tmp, "SD_STR_TITLE.awb"), os.path.join(tmp, "t.wav")), os.path.join(out, "title.m4a"))
    for sub, name in [(1, "move"), (2, "select"), (3, "back")]:
        m4a(vg_wav(os.path.join(tmp, "GAME_START_SE.acb"), os.path.join(tmp, f"{name}.wav"), sub, once=False), os.path.join(out, f"{name}.m4a"))


def shiningpearl(g, out, tmp, args):
    import UnityPy
    from wwise_event_media import hirc, sections
    UnityPy.config.FALLBACK_UNITY_VERSION = "2019.4.27f1"
    aa = "/Data/StreamingAssets/AssetAssistant/"
    def textures(bundle):
        env = UnityPy.load(io.BytesIO(g.read(aa + bundle))); t = {}
        for o in env.objects:
            if o.type.name == "Texture2D":
                try: d = o.read(); t[d.m_Name] = d.image
                except Exception: pass
        return t
    logo = next(iter(textures("Dpr/movie/pea/logo/logo_pea_en").values()))
    logo.crop(logo.getchannel("A").getbbox()).save(os.path.join(out, "logo.png"))
    sky = "Environments/bg/arenas/sky/"
    t1, t17 = textures(sky + "s001"), textures(sky + "s017")
    t1["T_BC_001_Cloud_01"].save(os.path.join(out, "clouds.png"))
    t17["T_CB_017_FarMount_02"].save(os.path.join(out, "mountains-far.png"))
    t1["T_B_001_FarMount_02"].save(os.path.join(out, "mountains-near.png"))
    wb = "/Data/StreamingAssets/Audio/GeneratedSoundBanks/Switch/"
    bank = g.read(wb + "Delphis_Main.bnk"); ids_h = g.read(wb + "Wwise_IDs.h").decode()
    objs = hirc(bank)
    names = dict((m[1], int(m[2])) for m in re.finditer(r"AkUniqueID (\w+) = (\d+)U", ids_h))
    didx, data = {}, b""
    for tag, body in sections(bank):
        if tag == "DIDX":
            for i in range(0, len(body), 12): mid, off, sz = struct.unpack_from("<III", body, i); didx[mid] = (off, sz)
        if tag == "DATA": data = body
    def media(oid, d=0, seen=None):
        seen = seen if seen is not None else set()
        if oid in seen or d > 4 or oid not in objs: return set()
        seen.add(oid); t, p = objs[oid]
        vals = {struct.unpack_from("<I", p, i)[0] for i in range(0, len(p) - 3)}
        found = {v for v in vals if v in didx}
        for v in vals:
            if v in objs and objs[v][0] in (2, 3, 5, 6, 9) and v != oid: found |= media(v, d + 1, seen)
        return found
    for ev, name in [("UI_COMMON_SELECT", "move"), ("UI_COMMON_DECIDE", "select"), ("UI_COMMON_CANCEL", "back")]:
        mid = sorted(media(names[ev]))[0]; off, sz = didx[mid]
        open(os.path.join(tmp, f"{name}.wem"), "wb").write(data[off:off + sz])
        m4a(vg_wav(os.path.join(tmp, f"{name}.wem"), os.path.join(tmp, f"{name}.wav"), once=False), os.path.join(out, f"{name}.m4a"))
    for letter, mid in zip("abcde", [17520047, 994857557, 730199546, 296675106, 439291133]):
        g.save(wb + f"{mid}.wem", os.path.join(tmp, f"{mid}.wem"))
        m4a(vg_wav(os.path.join(tmp, f"{mid}.wem"), os.path.join(tmp, f"{letter}.wav")), os.path.join(out, f"music-{letter}.m4a"))
    os.makedirs(os.path.join(out, "profile"), exist_ok=True)
    shutil.copy(os.path.join(KIT, "recipes/shiningpearl/game.tsv"), os.path.join(out, "profile/game.tsv"))


def pokopia(g, out, tmp, args):
    import kt_rdb
    want = {"3a160928": "music", "830b0c30": "sounds"}   # sound headers (ASRS entries) by file id
    for a in kt_rdb.archives(g.img):
        with romfs.Path(a).open("rb") as f: buf = f.read()
        for p, hdr, st, real, fid, tid, fl in kt_rdb.entries(buf):
            key = f"{fid:08x}"
            if key in want and kt_rdb.payload(buf, p, hdr, st, real, fl, limit=4) == b"ASRS":
                d = kt_rdb.payload(buf, p, hdr, st, real, fl)
                open(os.path.join(tmp, want[key] + ".ktsl2asbin"), "wb").write(d[d.find(b"KTSR"):])
    stream = g.read("/motor_asset_re/KIDS_PLATFORM_OUNCE/data/0x272c6efb.file")
    open(os.path.join(tmp, "music.ktsl2stbin"), "wb").write(stream[stream.find(b"KTSR"):]); del stream
    hdr = os.path.join(tmp, "music.ktsl2asbin")
    for n, sub in enumerate([106, 107, 85, 89, 134, 138, 3, 35], 1):
        m4a(vg_wav(hdr, os.path.join(tmp, f"m{n}.wav"), sub), os.path.join(out, f"music-{n}.m4a"))
    snd = os.path.join(tmp, "sounds.ktsl2asbin")
    for sub, name in [(58, "move"), (60, "select"), (37, "back"), (147, "start")]:
        m4a(vg_wav(snd, os.path.join(tmp, f"{name}.wav"), sub, once=False), os.path.join(out, f"{name}.m4a"))
    mv1 = g.save("/movie_asset/ounce/MV01.webm", os.path.join(tmp, "MV01.webm"))
    mv2 = g.save("/movie_asset/ounce/MV02.webm", os.path.join(tmp, "MV02.webm"))
    shots = [(mv1, t) for t in (63, 69, 75, 87, 93, 135, 141, 171)] + [(mv2, t) for t in (17, 29, 61)]
    for i, (mv, t) in enumerate(shots, 1): frame_at(mv, t, os.path.join(out, f"bg{i}.jpg"))
    icon = g.icon(os.path.join(tmp, "icon.png"))           # logo: the badge on the game's icon, by its white outline
    W, H = icon.size; px = icon.load(); b = Image.new("L", (W, H)); bp = b.load()
    for y in range(H):
        for x in range(W):
            r, gg, bb = px[x, y]; bp[x, y] = 255 if (r > 228 and gg > 228 and bb > 228) else 0
    b = b.filter(ImageFilter.MaxFilter(5))
    for s in [(2, 2), (W - 3, 2), (2, H - 3), (W - 3, H - 3), (W // 2, H - 3)]:
        if b.getpixel(s) == 0: ImageDraw.floodfill(b, s, 128)
    mask = b.point(lambda v: 0 if v == 128 else 255).filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(1))
    im = icon.convert("RGBA"); im.putalpha(mask); im = im.crop(mask.getbbox())
    a = im.getchannel("A"); m = a.point(lambda v: 255 if v > 40 else 0)
    ImageDraw.floodfill(m, (512, 250), 128)                 # keep only the badge, from its middle
    a = Image.composite(a, Image.new("L", a.size, 0), m.point(lambda v: 255 if v == 128 else 0))
    im.putalpha(a); im.crop(a.getbbox()).save(os.path.join(out, "logo.png"))


def fireemblem(g, out, tmp, args):
    for n, name in enumerate(["BGM_SYS_Title1_lp", "BGM_SYS_MainTheme1", "BGM_SYS_MainTheme1_B", "BGM_SYS_Prepare1_lp",
                              "BGM_SYS_Prepare2_lp", "BGM_SYS_Prepare3_lp", "BGM_SYS_Narration1_lp"], 1):
        src = g.save(g.find(name + ".opus"), os.path.join(tmp, name + ".opus"))
        m4a(vg_wav(src, os.path.join(tmp, f"m{n}.wav")), os.path.join(out, f"music-{n}.m4a"))
    sar = g.read(g.find("SE_Boot.bfsar")); waves, pos = [], 0      # 9 BFWAVs; names sort in the same order
    while (i := sar.find(b"FWAV", pos)) >= 0:
        e = "<" if sar[i + 4:i + 6] == b"\xff\xfe" else ">"
        waves.append(sar[i:i + struct.unpack_from(e + "I", sar, i + 0x0C)[0]]); pos = i + 4
    for idx, name in [(1, "move"), (3, "select"), (0, "back"), (2, "start")]:
        open(os.path.join(tmp, f"{name}.bfwav"), "wb").write(waves[idx])
        m4a(vg_wav(os.path.join(tmp, f"{name}.bfwav"), os.path.join(tmp, f"{name}.wav"), once=False), os.path.join(out, f"{name}.m4a"))
    fr = os.path.join(tmp, "frames"); os.makedirs(fr, exist_ok=True)
    for mv in ["MV00_00", "MV00_01", "MV00_05"]:
        frames_every(g.save(g.find(mv + ".webm"), os.path.join(tmp, mv + ".webm")), fr, 5, mv)
    picks = [f"MV00_01_{i:03d}" for i in (2, 6, 8, 12, 14, 15, 22, 23, 25)] + ["MV00_00_020", "MV00_05_010"]
    for i, p in enumerate(picks, 1): shutil.copy(os.path.join(fr, p + ".jpg"), os.path.join(out, f"bg{i}.jpg"))
    icon = g.icon(os.path.join(tmp, "icon.png")).crop((60, 745, 1000, 950))   # the wordmark on the icon
    W, H = icon.size; px = icon.load(); a = Image.new("L", (W, H)); ap = a.load()
    for y in range(H):
        for x in range(W):
            r, gg, b = px[x, y]; mx, mn = max(r, gg, b), min(r, gg, b); lum = (r * 299 + gg * 587 + b * 114) / 1000; sat = (mx - mn) / (mx + 1)
            v = (lum - 175) * 4 if (y < 110 and lum > 175 and sat < 0.30) else (lum - 125) * 3 if (y >= 110 and lum > 125 and sat < 0.55) else 0
            ap[x, y] = int(max(0, min(255, v)))
    a = a.filter(ImageFilter.MedianFilter(3))
    logo = Image.new("RGBA", (W, H), (250, 242, 222, 0)); logo.putalpha(a); logo.crop(a.getbbox()).save(os.path.join(out, "logo.png"))


def oot(g, out, tmp, args):
    title = g.save(g.find("Dm_Title_0005.bwav"), os.path.join(tmp, "title.bwav"))
    m4a(vg_wav(title, os.path.join(tmp, "t.wav"), once=False), os.path.join(out, "music-1.m4a"))    # 6-channel → stereo
    for n, name in enumerate(["BGM_GreatFairyFountain", "BGM_KokiriForest", "BGM_LostWood", "BGM_ZeldaGarden", "BGM_LonLonRanch",
                              "BGM_GoronCity", "BGM_ZoraDomain", "BGM_ShrineOfTime_Child", "BGM_SacredForestMeadow"], 2):
        src = g.save(g.find(name + ".bwav"), os.path.join(tmp, name + ".bwav"))
        m4a(vg_wav(src, os.path.join(tmp, f"m{n}.wav")), os.path.join(out, f"music-{n}.m4a"))
    for name, k in [("SE_Sys_Cursor00", "move"), ("SE_Sys_Do00", "select"), ("SE_Sys_Cancel00", "back")]:
        src = g.save(g.find(name + ".bwav"), os.path.join(tmp, name + ".bwav"))
        m4a(vg_wav(src, os.path.join(tmp, f"{k}.wav"), once=False), os.path.join(out, f"{k}.m4a"))
    fr = os.path.join(tmp, "frames"); os.makedirs(fr, exist_ok=True)
    for mv in ["Dm_Title_0005", "Dm_LostWood_0021", "Dm_TimeTemple_0095", "Dm_SageRoom_0020"]:
        frames_every(g.save("/Event/Movie/" + mv + ".webm", os.path.join(tmp, mv + ".webm")), fr, 4, mv)
    picks = [f"Dm_Title_0005_{i:03d}" for i in (4, 8, 9, 10, 11, 14, 16, 17, 21)] + ["Dm_LostWood_0021_002", "Dm_TimeTemple_0095_010", "Dm_SageRoom_0020_008"]
    for i, p in enumerate(picks, 1): shutil.copy(os.path.join(fr, p + ".jpg"), os.path.join(out, f"bg{i}.jpg"))
    if args.cover:   # the logo needs a cover picture with it (e.g. the 1200x675 cover a dump tool saves in imgs/covers/)
        im = Image.open(args.cover).convert("RGB").resize((1200, 675)).crop((630, 120, 1185, 530)); W, H = im.size; px = im.load()
        m = Image.new("L", (W, H)); mp = m.load()
        for y in range(H):
            for x in range(W):
                r, gg, b = px[x, y]; lum = (r * 299 + gg * 587 + b * 114) / 1000; greenish = gg > r + 6 and gg >= b - 8
                mp[x, y] = 255 if not (lum < 58 or (greenish and lum < 150)) else 0
        cut(im, keep_big_pieces(m.filter(ImageFilter.MedianFilter(3)), 60), os.path.join(out, "logo.png"), blur=0.7)
    else:
        print("note: no --cover given, so the launcher shows the title in text instead of the logo")


def firered(g, out, tmp, args):
    icon = g.icon(os.path.join(tmp, "icon.png"))
    crop = icon.crop((130, 40, 900, 440)); W, H = crop.size; px = crop.load(); m = Image.new("L", (W, H)); mp = m.load()
    for y in range(H):
        for x in range(W):
            r, gg, b = px[x, y]; swirl = r > gg + 45 and r > b + 70 and gg < 190
            keep = (235 <= x <= 570 and max(r, gg, b) - min(r, gg, b) < 38 and not b > gg + 12) if y > 238 else not swirl
            mp[x, y] = 255 if keep else 0
    cut(crop, m.filter(ImageFilter.MedianFilter(5)).filter(ImageFilter.MinFilter(3)), os.path.join(out, "logo.png"))
    BW, BH = 1920, 1080
    bg = icon.resize((BW, BW)).crop((0, (BW - BH) // 2, BW, (BW - BH) // 2 + BH)).filter(ImageFilter.GaussianBlur(40))
    char = icon.crop((40, 430, 1024, 1024)); s = BH * 0.98 / char.height; char = char.resize((int(char.width * s), int(char.height * s)))
    cw, ch = char.size; mask = Image.new("L", (cw, ch), 0)
    ImageDraw.Draw(mask).rounded_rectangle((int(cw * 0.12), int(ch * 0.10), cw + 200, ch + 200), radius=260, fill=255)
    bg.paste(char, (BW - cw + 40, BH - ch + 10), mask.filter(ImageFilter.GaussianBlur(80)))
    bg.save(os.path.join(out, "bg1.jpg"), quality=90)
    print("note: FireRed's music is sequenced GBA audio; add your own music files to the theme's playlist")


RECIPES = {"suikoden": suikoden, "shiningpearl": shiningpearl, "pokopia": pokopia,
           "fireemblem": fireemblem, "oot": oot, "firered": firered}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("game", choices=sorted(RECIPES))
    ap.add_argument("app", help="the nxnative-built game app, or a launcher with it inside")
    ap.add_argument("--cover", help="Ocarina of Time only: a cover picture to take the logo from")
    ap.add_argument("--out", help="theme folder to write (default: themes/<game>)")
    args = ap.parse_args()
    out = os.path.abspath(args.out or os.path.join(KIT, "themes", args.game)); os.makedirs(out, exist_ok=True)
    g = Game(args.app)
    with tempfile.TemporaryDirectory(prefix="nxtheme_") as tmp:
        print(f"making the {args.game} theme from {g.app} …")
        RECIPES[args.game](g, out, tmp, args)
    theme = json.load(open(os.path.join(KIT, "recipes", args.game, "theme.json")))
    if args.game == "oot" and not os.path.exists(os.path.join(out, "logo.png")): theme.pop("logo", None)
    icns = os.path.join(g.app, "Contents/Resources/AppIcon.icns")
    if os.path.exists(icns): shutil.copy(icns, os.path.join(out, "AppIcon.icns"))
    json.dump(theme, open(os.path.join(out, "theme.json"), "w"), indent=2, ensure_ascii=False)
    print(f"done: {out}")


if __name__ == "__main__":
    main()
