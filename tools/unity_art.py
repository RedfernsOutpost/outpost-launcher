"""Find and export textures from a Unity Addressables game inside an nxnative RomFS image.

    python unity_art.py <RomFS.img> <out dir> <regex> [--list]

Reads aa/catalog.json to map asset keys to their bundles, opens only those bundles
(read in place from the image with nxnative's romfs reader) and saves every Texture2D
or Sprite they hold as PNG. --list only prints the matching keys.
"""
import base64, io, json, os, re, struct, sys

sys.path.insert(0, os.path.join(os.path.expanduser(os.environ.get("NXNATIVE", "~/nxnative")), "dm/tools"))
import romfs  # noqa: E402

AA = "/Data/StreamingAssets/aa"


def read_key(buf, off):
    t = buf[off]
    if t == 0:   # ascii
        n = struct.unpack_from("<i", buf, off + 1)[0]; return buf[off + 5:off + 5 + n].decode("ascii", "replace")
    if t == 1:   # unicode
        n = struct.unpack_from("<i", buf, off + 1)[0]; return buf[off + 5:off + 5 + n].decode("utf-16-le", "replace")
    if t in (2, 3, 4):
        return str(struct.unpack_from({2: "<H", 3: "<I", 4: "<i"}[t], buf, off + 1)[0])
    return None


def catalog(img):
    with romfs.Path(img + AA + "/catalog.json").open("rb") as f:
        d = json.load(f)
    ids = d["m_InternalIds"]
    keys = base64.b64decode(d["m_KeyDataString"])
    buckets_raw = base64.b64decode(d["m_BucketDataString"])
    entries_raw = base64.b64decode(d["m_EntryDataString"])
    buckets, p = [], 4
    for _ in range(struct.unpack_from("<i", buckets_raw, 0)[0]):
        off, n = struct.unpack_from("<ii", buckets_raw, p); p += 8
        ents = list(struct.unpack_from(f"<{n}i", buckets_raw, p)); p += 4 * n
        buckets.append((read_key(keys, off), ents))
    n_ent = struct.unpack_from("<i", entries_raw, 0)[0]
    entries = [struct.unpack_from("<7i", entries_raw, 4 + 28 * i) for i in range(n_ent)]
    return ids, buckets, entries


def bundles_for(ids, buckets, entries, key_index):
    """Bundle file names an asset key's entries depend on."""
    out = set()
    for e in buckets[key_index][1]:
        dep = entries[e][2]
        if dep < 0: continue
        for be in buckets[dep][1]:
            iid = ids[entries[be][0]]
            if iid.endswith(".bundle"): out.add(iid.rsplit("/", 1)[-1])
    return out


def main():
    img, outdir, pat = sys.argv[1], sys.argv[2], re.compile(sys.argv[3], re.I)
    ids, buckets, entries = catalog(img)
    hits = [(i, k) for i, (k, _) in enumerate(buckets) if k and pat.search(k)]
    print(f"{len(hits)} matching keys")
    if "--list" in sys.argv:
        for _, k in hits: print(k)
        return
    import UnityPy
    UnityPy.config.FALLBACK_UNITY_VERSION = os.environ.get("UNITY_VERSION", "2022.3.28f1")
    os.makedirs(outdir, exist_ok=True)
    wanted = {}
    for i, k in hits:
        for b in bundles_for(ids, buckets, entries, i): wanted.setdefault(b, []).append(k)
    print(f"{len(wanted)} bundles to open")
    saved = 0
    for b in sorted(wanted):
        with romfs.Path(f"{img}{AA}/Switch/{b}").open("rb") as f:
            env = UnityPy.load(io.BytesIO(f.read()))
        for obj in env.objects:
            if obj.type.name not in ("Texture2D", "Sprite"): continue
            try:
                data = obj.read()
                name = getattr(data, "m_Name", "") or getattr(data, "name", "") or f"{b[:8]}_{obj.path_id}"
                if not pat.search(name) and not any(pat.search(k) for k in wanted[b]): continue
                im = data.image
                if im.width < 64 or im.height < 64: continue
                path = os.path.join(outdir, f"{obj.type.name[0]}_{re.sub(r'[^A-Za-z0-9_.-]', '_', name)}.png")
                if not os.path.exists(path):
                    im.save(path); saved += 1
            except Exception as e:  # some formats can't be decoded; skip them
                print("skip", b, obj.path_id, type(e).__name__)
    print(f"saved {saved} images to {outdir}")


if __name__ == "__main__":
    main()
