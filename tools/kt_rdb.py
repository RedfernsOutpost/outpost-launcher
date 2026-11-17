"""Koei Tecmo "motor" RDB archives (.fdata entries, IDRK0000) inside an nxnative RomFS image.

    python kt_rdb.py <romfs.img> scan                 # list entry types (by first bytes) per archive
    python kt_rdb.py <romfs.img> extract <out> <magic> [maxn]   # save entries whose data starts with magic

Entry layout (worked out from the files; little-endian):
  0  "IDRK0000"
  8  u64 entry size (header + data)      16 u64 stored size      24 u64 real size
  32 u32 ?   36 u32 file id   40 u32 type id   44 u32 flags (0x00400000 = zlib chunks)
  header size = entry size - stored size; entries are 16-byte aligned in the .fdata.
Stored data, when compressed: chunks of  u16 len(+2 = zlib stream length), 8 unknown bytes,
then a zlib stream; a 1-byte prefix sits before the first chunk.
"""
import io, os, struct, sys, zlib, collections

sys.path.insert(0, os.path.join(os.path.expanduser(os.environ.get("NXNATIVE", "~/nxnative")), "dm/tools"))
import romfs  # noqa: E402

BASE = "/motor_asset_re/KIDS_PLATFORM_OUNCE"


def entries(buf):
    p = buf.find(b"IDRK0000")
    while 0 <= p < len(buf) - 48:
        if buf[p:p + 8] != b"IDRK0000":
            p = buf.find(b"IDRK0000", p + 1); continue
        size, stored, real = struct.unpack_from("<QQQ", buf, p + 8)
        _, fid, tid, flags = struct.unpack_from("<IIII", buf, p + 32)
        hdr = size - stored
        yield p, hdr, stored, real, fid, tid, flags
        p = (p + size + 15) & ~15


def payload(buf, p, hdr, stored, real, flags, limit=None):
    data = buf[p + hdr:p + hdr + stored]
    if stored == real:
        return data[:limit] if limit else data
    out, q = bytearray(), 0
    # find the first zlib stream, then walk chunks: [u16 len][8 bytes][zlib len+2]
    z = data.find(b"\x78\x9c")
    q = max(0, z - 10)
    while q + 10 < len(data):
        clen = struct.unpack_from("<H", data, q)[0] + 2
        start = q + 10
        if data[start:start + 1] != b"\x78":
            # resync on the next zlib header
            nz = data.find(b"\x78\x9c", q + 1)
            if nz < 0: break
            q = nz - 10; continue
        try:
            out += zlib.decompress(data[start:start + clen])
        except zlib.error:
            out += zlib.decompressobj().decompress(data[start:])
            break
        q = start + clen
        if limit and len(out) >= limit: break
    return bytes(out[:limit] if limit else out)


def archives(img):
    for root, dirs, files in romfs.walk(img + BASE):
        for f in files:
            if f.endswith(".fdata"): yield root + "/" + f


def main():
    img, cmd = sys.argv[1], sys.argv[2]
    if cmd == "scan":
        tot = collections.Counter()
        for a in archives(img):
            with romfs.Path(a).open("rb") as f: buf = f.read()
            c = collections.Counter()
            for p, hdr, st, real, fid, tid, fl in entries(buf):
                head = payload(buf, p, hdr, st, real, fl, limit=8)
                c[head[:4]] += 1
            print(a.split(BASE)[-1], dict(c.most_common(8))); tot.update(c)
        print("TOTAL", dict(tot.most_common(20)))
    elif cmd == "extract":
        out, magic = sys.argv[3], sys.argv[4].encode()
        maxn = int(sys.argv[5]) if len(sys.argv) > 5 else 10**9
        os.makedirs(out, exist_ok=True); n = 0
        for a in archives(img):
            with romfs.Path(a).open("rb") as f: buf = f.read()
            for p, hdr, st, real, fid, tid, fl in entries(buf):
                if payload(buf, p, hdr, st, real, fl, limit=8)[:len(magic)] != magic: continue
                data = payload(buf, p, hdr, st, real, fl)
                open(f"{out}/{fid:08x}_{tid:08x}.bin", "wb").write(data); n += 1
                if n >= maxn: print("saved", n); return
        print("saved", n)


if __name__ == "__main__":
    main()
